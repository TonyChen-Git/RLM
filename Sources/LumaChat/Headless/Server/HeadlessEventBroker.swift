import Foundation
import LumaChatSDK

/// Bounded replay/event fan-out for a production runtime adapter. Agent events
/// are projected into this broker; the HTTP layer only consumes its streams.
/// The broker never drives an Agent run and therefore cannot diverge from the
/// app's runtime or persistence state.
actor LumaChatHeadlessEventBroker {
    enum BrokerError: LocalizedError, Equatable, Sendable {
        case eventTooLarge
        case sequenceExhausted

        var errorDescription: String? {
            switch self {
            case .eventTooLarge: "Headless event exceeds the replay safety limit."
            case .sequenceExhausted: "Headless event sequence is exhausted."
            }
        }
    }

    private struct Subscriber {
        let continuation: AsyncThrowingStream<LumaChatTaskEvent, Error>.Continuation
    }

    private struct TaskChannel {
        var nextSequence: UInt64 = 1
        var retained: [(event: LumaChatTaskEvent, byteCount: Int)] = []
        var retainedBytes = 0
        var subscribers: [UUID: Subscriber] = [:]
        var isFinished = false
    }

    private let maximumRetainedEvents: Int
    private let maximumRetainedBytes: Int
    private let maximumEventBytes: Int
    private let maximumLiveBufferedBytes: Int
    private let maximumLiveBufferedEvents: Int
    private let maximumSubscribersPerTask: Int
    private var channels: [UUID: TaskChannel] = [:]

    init(
        maximumRetainedEvents: Int = 512,
        maximumRetainedBytes: Int = 16_777_216,
        maximumEventBytes: Int = LumaChatHeadlessServerConfiguration.defaultMaximumEventBytes,
        maximumLiveBufferedBytes: Int = 16_777_216,
        maximumSubscribersPerTask: Int = 32
    ) {
        self.maximumRetainedEvents = max(1, min(maximumRetainedEvents, 4_096))
        self.maximumRetainedBytes = max(1_024, min(maximumRetainedBytes, 67_108_864))
        let eventLimit = max(1_024, min(maximumEventBytes, 1_048_576))
        let liveLimit = max(eventLimit, min(maximumLiveBufferedBytes, 67_108_864))
        self.maximumEventBytes = eventLimit
        self.maximumLiveBufferedBytes = liveLimit
        // AsyncThrowingStream exposes a count-based buffer but no dequeue byte
        // accounting. Each event is bounded above, so this count guarantees a
        // hard aggregate byte ceiling even for a stalled subscriber.
        self.maximumLiveBufferedEvents = max(
            1,
            min(256, liveLimit / eventLimit)
        )
        self.maximumSubscribersPerTask = max(1, min(maximumSubscribersPerTask, 256))
    }

    @discardableResult
    func publish(
        taskID: UUID,
        kind: LumaChatTaskEventKind,
        payload: LumaChatJSONValue,
        timestamp: Date = Date(),
        reopenFinishedStream: Bool = false
    ) throws -> LumaChatTaskEvent {
        var channel = channels[taskID] ?? TaskChannel()
        guard channel.nextSequence < UInt64.max else { throw BrokerError.sequenceExhausted }
        let event = LumaChatTaskEvent(
            sequence: channel.nextSequence,
            taskID: taskID,
            kind: kind,
            timestamp: timestamp,
            payload: payload
        )
        let byteCount = try encodedByteCount(event)
        guard byteCount <= maximumEventBytes else { throw BrokerError.eventTooLarge }
        channel.nextSequence += 1
        // Only an explicit new run may reopen a terminal stream. Late runtime
        // observations remain replayable but cannot accidentally make a
        // completed task look live again.
        if reopenFinishedStream { channel.isFinished = false }
        channel.retained.append((event, byteCount))
        channel.retainedBytes += byteCount
        trim(&channel)

        var terminated: [UUID] = []
        for (id, subscriber) in channel.subscribers {
            switch subscriber.continuation.yield(event) {
            case .enqueued:
                break
            case .dropped:
                subscriber.continuation.finish(throwing: LumaChatHeadlessRuntimeFailure.eventCursorExpired(
                    "The event consumer fell behind the bounded live buffer."
                ))
                terminated.append(id)
            case .terminated:
                terminated.append(id)
            @unknown default:
                subscriber.continuation.finish(throwing: LumaChatHeadlessRuntimeFailure.eventCursorExpired())
                terminated.append(id)
            }
        }
        for id in terminated { channel.subscribers.removeValue(forKey: id) }
        channels[taskID] = channel
        return event
    }

    func stream(
        taskID: UUID,
        afterSequence: UInt64?
    ) throws -> AsyncThrowingStream<LumaChatTaskEvent, Error> {
        var channel = channels[taskID] ?? TaskChannel()
        let cursor = afterSequence ?? 0
        let newest = channel.nextSequence - 1
        guard cursor <= newest else {
            throw LumaChatHeadlessRuntimeFailure.conflict("Event cursor is ahead of the task stream.")
        }
        if let oldest = channel.retained.first?.event.sequence,
           cursor < oldest - 1 {
            throw LumaChatHeadlessRuntimeFailure.eventCursorExpired()
        }
        guard channel.subscribers.count < maximumSubscribersPerTask else {
            throw LumaChatHeadlessRuntimeFailure.conflict(
                "Task has too many live event subscribers."
            )
        }

        let subscriberID = UUID()
        let replay = channel.retained.lazy
            .map(\.event)
            .filter { $0.sequence > cursor }
        let pair = AsyncThrowingStream<LumaChatTaskEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(maximumLiveBufferedEvents)
        )
        for event in replay {
            guard case .enqueued = pair.continuation.yield(event) else {
                pair.continuation.finish(throwing: LumaChatHeadlessRuntimeFailure.eventCursorExpired(
                    "Replay exceeds the bounded stream buffer."
                ))
                return pair.stream
            }
        }
        if channel.isFinished {
            pair.continuation.finish()
            channels[taskID] = channel
            return pair.stream
        }
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeSubscriber(id: subscriberID, taskID: taskID) }
        }
        channel.subscribers[subscriberID] = Subscriber(continuation: pair.continuation)
        channels[taskID] = channel
        return pair.stream
    }

    func finish(taskID: UUID, failure: LumaChatHeadlessRuntimeFailure? = nil) {
        guard var channel = channels[taskID] else { return }
        for subscriber in channel.subscribers.values {
            if let failure {
                subscriber.continuation.finish(throwing: failure)
            } else {
                subscriber.continuation.finish()
            }
        }
        channel.subscribers.removeAll()
        channel.isFinished = true
        channels[taskID] = channel
    }

    func latestSequence(taskID: UUID) -> UInt64 {
        guard let channel = channels[taskID] else { return 0 }
        return channel.nextSequence - 1
    }

    func removeRetainedEvents(taskID: UUID) {
        guard var channel = channels[taskID] else { return }
        channel.retained.removeAll()
        channel.retainedBytes = 0
        // Keep the sequence/terminal state even when no subscriber is live;
        // otherwise a later event could reuse sequence 1 for the same task.
        channels[taskID] = channel
    }

    private func removeSubscriber(id: UUID, taskID: UUID) {
        guard var channel = channels[taskID] else { return }
        channel.subscribers.removeValue(forKey: id)
        channels[taskID] = channel
    }

    private func trim(_ channel: inout TaskChannel) {
        while channel.retained.count > maximumRetainedEvents
            || channel.retainedBytes > maximumRetainedBytes {
            guard !channel.retained.isEmpty else { break }
            let removed = channel.retained.removeFirst()
            channel.retainedBytes -= removed.byteCount
        }
    }

    private func encodedByteCount(_ event: LumaChatTaskEvent) throws -> Int {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(event).count
    }
}
