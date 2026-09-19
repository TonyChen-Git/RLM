import Darwin
import Dispatch
import Foundation
import LumaPTYSupport

enum PseudoTerminalError: LocalizedError, Sendable, Equatable {
    case alreadyStarted
    case disposed
    case invalidCommand
    case invalidShell(String)
    case invalidDimensions
    case invalidOutputOffset(Int64)
    case notStarted
    case notRunning
    case inputBusy
    case inputTooLarge(maxBytes: Int)
    case inputBackpressure(bytesWritten: Int)
    case workspaceBoundary(String)
    case spawnFailed(stage: Int32, errorCode: Int32)
    case operationFailed(operation: String, errorCode: Int32)

    var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            "This PTY session has already been started."
        case .disposed:
            "This PTY session has been disposed."
        case .invalidCommand:
            "The PTY command is empty, oversized, or contains a NUL byte."
        case .invalidShell(let shell):
            "Unsupported PTY shell: \(shell)"
        case .invalidDimensions:
            "PTY rows and columns must each be between 1 and 1,000."
        case .invalidOutputOffset(let offset):
            "PTY output offset is beyond the current stream: \(offset)."
        case .notStarted:
            "This PTY session has not been started."
        case .notRunning:
            "This PTY process is no longer running."
        case .inputBusy:
            "A PTY input write is already in progress."
        case .inputTooLarge(let maxBytes):
            "PTY input exceeds the \(maxBytes)-byte limit."
        case .inputBackpressure(let bytesWritten):
            "The PTY did not accept more input in time (\(bytesWritten) bytes written)."
        case .workspaceBoundary(let path):
            "PTY path is outside the selected workspace: \(path)"
        case .spawnFailed(let stage, let errorCode):
            "PTY spawn failed at stage \(stage): \(Self.posixMessage(errorCode))"
        case .operationFailed(let operation, let errorCode):
            "PTY \(operation) failed: \(Self.posixMessage(errorCode))"
        }
    }

    private static func posixMessage(_ errorCode: Int32) -> String {
        guard let message = strerror(errorCode) else { return "errno \(errorCode)" }
        return "\(String(cString: message)) (errno \(errorCode))"
    }
}

struct PseudoTerminalDimensions: Codable, Sendable, Equatable {
    var rows: UInt16
    var columns: UInt16
}

enum PseudoTerminalState: String, Codable, Sendable {
    case running
    case exited
    case stopped
    case failed
}

struct PseudoTerminalStatus: Codable, Sendable, Equatable {
    var id: UUID
    var processIdentifier: Int32
    var state: PseudoTerminalState
    var exitCode: Int32?
    var terminationSignal: Int32?
    var dimensions: PseudoTerminalDimensions
    var startedAt: Date
    var duration: TimeInterval
    var transportErrorCode: Int32?
}

/// A bounded raw-byte view over the combined PTY stream. Escape sequences are
/// untrusted bytes; this transport never interprets OSC, clipboard, links, or
/// terminal control actions.
struct PseudoTerminalOutput: Codable, Sendable, Equatable {
    var id: UUID
    var data: Data
    var offset: Int64
    var nextOffset: Int64
    var earliestAvailableOffset: Int64
    var hasMore: Bool
    var truncatedBeforeOffset: Bool
}

struct PseudoTerminalWriteResult: Codable, Sendable, Equatable {
    var id: UUID
    var bytesWritten: Int
}

struct PseudoTerminalOutputBounds: Codable, Sendable, Equatable {
    var earliestAvailableOffset: Int64
    var nextOffset: Int64
}

private struct PseudoTerminalByteRing {
    let capacity: Int
    private(set) var totalBytes: Int64 = 0
    private var storage: [UInt8]
    private var head = 0
    private var count = 0

    init(capacity: Int) {
        self.capacity = capacity
        storage = [UInt8](repeating: 0, count: capacity)
    }

    var earliestOffset: Int64 { totalBytes - Int64(count) }

    mutating func append(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        if bytes.count >= capacity {
            let suffix = bytes.suffix(capacity)
            storage.replaceSubrange(0..<capacity, with: suffix)
            head = 0
            count = capacity
            totalBytes += Int64(bytes.count)
            return
        }

        for byte in bytes {
            if count < capacity {
                storage[(head + count) % capacity] = byte
                count += 1
            } else {
                storage[head] = byte
                head = (head + 1) % capacity
            }
        }
        totalBytes += Int64(bytes.count)
    }

    func read(offset requestedOffset: Int64, maxBytes: Int) -> PseudoTerminalRingRead? {
        guard requestedOffset <= totalBytes else { return nil }
        let startOffset = max(requestedOffset, earliestOffset)
        let available = Int(totalBytes - startOffset)
        let length = min(maxBytes, available)
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        let logicalStart = Int(startOffset - earliestOffset)
        for index in 0..<length {
            bytes.append(storage[(head + logicalStart + index) % capacity])
        }
        return PseudoTerminalRingRead(
            data: Data(bytes),
            offset: startOffset,
            nextOffset: startOffset + Int64(length),
            earliestOffset: earliestOffset,
            hasMore: length < available,
            truncatedBeforeOffset: requestedOffset < earliestOffset
        )
    }

    var bounds: PseudoTerminalOutputBounds {
        PseudoTerminalOutputBounds(
            earliestAvailableOffset: earliestOffset,
            nextOffset: totalBytes
        )
    }
}

private struct PseudoTerminalRingRead {
    var data: Data
    var offset: Int64
    var nextOffset: Int64
    var earliestOffset: Int64
    var hasMore: Bool
    var truncatedBeforeOffset: Bool
}

/// Tracks the forkpty session and every observed descendant by PID plus kernel
/// start time. Job-control may move commands into other process groups and a
/// child may call setsid(); verified identities let cleanup signal those owned
/// processes without ever targeting a recycled PID.
private final class PseudoTerminalDescendantTracker: @unchecked Sendable {
    private static let maximumTrackedProcesses = 1_024
    private let rootProcessIdentifier: Int32
    private let lock = NSLock()
    private var identities: [Int32: LumaPTYProcessIdentity] = [:]
    private var monitors: [Int32: DispatchSourceProcess] = [:]
    private var didCancel = false

    init(rootProcessIdentifier: Int32) {
        self.rootProcessIdentifier = rootProcessIdentifier
        var root = LumaPTYProcessIdentity(
            process_identifier: -1,
            start_seconds: 0,
            start_microseconds: 0
        )
        if luma_pty_process_identity(rootProcessIdentifier, &root) == 0 {
            install([root])
        }
        refresh()
    }

    deinit { cancel() }

    func refresh() {
        lock.lock()
        guard !didCancel else {
            lock.unlock()
            return
        }
        let known = Array(identities.values)
        lock.unlock()

        var discovered: [LumaPTYProcessIdentity] = []
        discovered.reserveCapacity(known.count + 16)
        discovered.append(contentsOf: listSession())
        var queue = known.map(\.process_identifier)
        var visited = Set<Int32>()
        var index = 0
        while index < queue.count,
              discovered.count < Self.maximumTrackedProcesses {
            let parent = queue[index]
            index += 1
            guard visited.insert(parent).inserted else { continue }
            let children = listChildren(of: parent)
            discovered.append(contentsOf: children)
            queue.append(contentsOf: children.map(\.process_identifier))
        }
        install(discovered)
    }

    func signalAll(_ signal: Int32) {
        refresh()
        lock.lock()
        let owned = identities.values.sorted {
            if $0.process_identifier == rootProcessIdentifier { return false }
            if $1.process_identifier == rootProcessIdentifier { return true }
            return $0.process_identifier > $1.process_identifier
        }
        lock.unlock()
        for var identity in owned {
            _ = luma_pty_signal_process_identity(&identity, signal)
        }
    }

    func cancel() {
        lock.lock()
        guard !didCancel else {
            lock.unlock()
            return
        }
        didCancel = true
        let sources = Array(monitors.values)
        monitors.removeAll()
        lock.unlock()
        for source in sources { source.cancel() }
    }

    private func listSession() -> [LumaPTYProcessIdentity] {
        var buffer = identityBuffer()
        let count = luma_pty_list_session_identities(
            rootProcessIdentifier,
            &buffer,
            Int32(buffer.count)
        )
        guard count > 0 else { return [] }
        return Array(buffer.prefix(Int(count)))
    }

    private func listChildren(of parent: Int32) -> [LumaPTYProcessIdentity] {
        var buffer = identityBuffer()
        let count = luma_pty_list_child_identities(
            parent,
            &buffer,
            Int32(buffer.count)
        )
        guard count > 0 else { return [] }
        return Array(buffer.prefix(Int(count)))
    }

    private func identityBuffer() -> [LumaPTYProcessIdentity] {
        [LumaPTYProcessIdentity](
            repeating: LumaPTYProcessIdentity(
                process_identifier: -1,
                start_seconds: 0,
                start_microseconds: 0
            ),
            count: Self.maximumTrackedProcesses
        )
    }

    private func install(_ candidates: [LumaPTYProcessIdentity]) {
        var sourcesToResume: [DispatchSourceProcess] = []
        lock.lock()
        guard !didCancel else {
            lock.unlock()
            return
        }
        for candidate in candidates
        where candidate.process_identifier > 1
            && identities[candidate.process_identifier] == nil
            && identities.count < Self.maximumTrackedProcesses {
            identities[candidate.process_identifier] = candidate
            let identifier = candidate.process_identifier
            let source = DispatchSource.makeProcessSource(
                identifier: identifier,
                eventMask: [.fork, .exec, .exit],
                queue: DispatchQueue.global(qos: .utility)
            )
            source.setEventHandler { [weak self, weak source] in
                guard let self else { return }
                self.refresh()
                if source?.data.contains(.exit) == true {
                    self.removeMonitor(identifier)
                }
            }
            monitors[identifier] = source
            sourcesToResume.append(source)
        }
        lock.unlock()
        for source in sourcesToResume { source.resume() }
    }

    private func removeMonitor(_ identifier: Int32) {
        lock.lock()
        let source = monitors.removeValue(forKey: identifier)
        identities.removeValue(forKey: identifier)
        lock.unlock()
        source?.cancel()
    }
}

private final class PseudoTerminalProcessRecord: @unchecked Sendable {
    enum DrainResult { case data, retry, finished, failed(Int32) }
    enum WriteResult { case success(Int), failure(Int32) }

    let id = UUID()
    let processIdentifier: Int32
    let startedAt = Date()
    let startedClock = ContinuousClock.now
    private let lock = NSLock()
    private var masterFileDescriptor: Int32
    private var ring: PseudoTerminalByteRing
    private var dimensions: PseudoTerminalDimensions
    private var waitStatus: LumaPTYWaitStatus?
    private var waitErrorCode: Int32?
    private var readerFinished = false
    private var readerErrorCode: Int32?
    private var stopped = false
    private var writing = false
    private let completionGroup = DispatchGroup()
    private var didPublishWaitCompletion = false
    private let descendantTracker: PseudoTerminalDescendantTracker
    private var outputSubscribers: [
        UUID: AsyncStream<PseudoTerminalOutput>.Continuation
    ] = [:]

    init(process: LumaPTYProcess, dimensions: PseudoTerminalDimensions, capacity: Int) {
        processIdentifier = process.process_identifier
        masterFileDescriptor = process.master_file_descriptor
        self.dimensions = dimensions
        ring = PseudoTerminalByteRing(capacity: capacity)
        descendantTracker = PseudoTerminalDescendantTracker(
            rootProcessIdentifier: process.process_identifier
        )
        completionGroup.enter()
        completionGroup.enter()
    }

    deinit {
        requestSignal(SIGKILL)
        closeMaster()
    }

    func drainOnce(buffer: inout [UInt8]) -> DrainResult {
        lock.lock()
        guard masterFileDescriptor >= 0 else {
            lock.unlock()
            return .finished
        }
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(masterFileDescriptor, bytes.baseAddress, bytes.count)
        }
        if count > 0 {
            let startOffset = ring.bounds.nextOffset
            ring.append(buffer.prefix(count))
            let read = ring.read(offset: startOffset, maxBytes: count)
            let continuations = Array(outputSubscribers.values)
            lock.unlock()
            if let read {
                let event = PseudoTerminalOutput(
                    id: id,
                    data: read.data,
                    offset: read.offset,
                    nextOffset: read.nextOffset,
                    earliestAvailableOffset: read.earliestOffset,
                    hasMore: read.hasMore,
                    truncatedBeforeOffset: read.truncatedBeforeOffset
                )
                for continuation in continuations { continuation.yield(event) }
            }
            return .data
        }
        if count == 0 || errno == EIO {
            lock.unlock()
            return .finished
        }
        if errno == EINTR {
            lock.unlock()
            return .data
        }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            lock.unlock()
            return .retry
        }
        let errorCode = Int32(errno)
        readerErrorCode = errorCode
        lock.unlock()
        return .failed(errorCode)
    }

    enum ReapResult { case pending, completed, failed }

    /// Polls with WNOWAIT, performs descendant cleanup while the direct child
    /// is still an unreaped zombie (so its PID/PGID cannot be reused), then
    /// reaps and publishes the final status before releasing the same lock used
    /// by every signal operation.
    func reapIfExited() -> ReapResult {
        lock.lock()
        defer { lock.unlock() }
        guard waitStatus == nil, waitErrorCode == nil else { return .completed }
        let readiness = luma_pty_has_waitable_exit(processIdentifier)
        if readiness == 0 { return .pending }
        guard readiness == 1 else {
            waitErrorCode = Int32(errno)
            descendantTracker.cancel()
            publishWaitCompletionLocked()
            return .failed
        }

        if masterFileDescriptor >= 0 {
            _ = luma_pty_signal_foreground_process_group(masterFileDescriptor, SIGTERM)
        }
        _ = luma_pty_signal_process_group(processIdentifier, SIGTERM)
        descendantTracker.signalAll(SIGTERM)
        usleep(50_000)
        if masterFileDescriptor >= 0 {
            _ = luma_pty_signal_foreground_process_group(masterFileDescriptor, SIGKILL)
        }
        _ = luma_pty_signal_process_group(processIdentifier, SIGKILL)
        descendantTracker.signalAll(SIGKILL)

        var status = LumaPTYWaitStatus(
            kind: LumaPTYWaitKindUnknown,
            code: 0,
            raw_status: 0,
            core_dumped: 0
        )
        guard luma_pty_wait(processIdentifier, 0, &status) == 1 else {
            waitErrorCode = Int32(errno)
            descendantTracker.cancel()
            publishWaitCompletionLocked()
            return .failed
        }
        waitStatus = status
        descendantTracker.cancel()
        publishWaitCompletionLocked()
        return .completed
    }

    func markReaderFinished() {
        var continuations: [AsyncStream<PseudoTerminalOutput>.Continuation] = []
        lock.lock()
        guard !readerFinished else {
            lock.unlock()
            return
        }
        readerFinished = true
        continuations = Array(outputSubscribers.values)
        outputSubscribers.removeAll()
        lock.unlock()
        completionGroup.leave()
        for continuation in continuations { continuation.finish() }
    }

    func beginWrite() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !writing else { return false }
        writing = true
        return true
    }

    func endWrite() {
        lock.lock()
        writing = false
        lock.unlock()
    }

    func write(_ data: Data, offset: Int) -> WriteResult {
        lock.lock()
        defer { lock.unlock() }
        guard masterFileDescriptor >= 0, waitStatus == nil, waitErrorCode == nil else {
            return .failure(ESRCH)
        }
        let count = data.withUnsafeBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            return Darwin.write(
                masterFileDescriptor,
                baseAddress.advanced(by: offset),
                data.count - offset
            )
        }
        return count >= 0 ? .success(count) : .failure(Int32(errno))
    }

    func resize(_ newDimensions: PseudoTerminalDimensions) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard masterFileDescriptor >= 0, waitStatus == nil, waitErrorCode == nil else {
            return ESRCH
        }
        guard luma_pty_resize(
            masterFileDescriptor,
            newDimensions.rows,
            newDimensions.columns,
            0,
            0
        ) == 0 else { return Int32(errno) }
        dimensions = newDimensions
        return nil
    }

    func requestStop() {
        lock.lock()
        guard waitStatus == nil, waitErrorCode == nil else {
            lock.unlock()
            return
        }
        stopped = true
        if masterFileDescriptor >= 0 {
            _ = luma_pty_signal_foreground_process_group(masterFileDescriptor, SIGTERM)
        }
        _ = luma_pty_signal_process_group(processIdentifier, SIGTERM)
        descendantTracker.signalAll(SIGTERM)
        lock.unlock()
    }

    func requestSignal(_ signal: Int32) {
        lock.lock()
        guard waitStatus == nil, waitErrorCode == nil else {
            lock.unlock()
            return
        }
        if masterFileDescriptor >= 0 {
            _ = luma_pty_signal_foreground_process_group(masterFileDescriptor, signal)
        }
        _ = luma_pty_signal_process_group(processIdentifier, signal)
        if signal == SIGTERM || signal == SIGKILL || signal == SIGHUP {
            descendantTracker.signalAll(signal)
        }
        lock.unlock()
    }

    func closeMaster() {
        lock.lock()
        closeMasterLocked()
        lock.unlock()
    }

    /// DispatchSourceRead's cancel handler is the sole normal owner of closing
    /// the registered descriptor. Matching the exact fd before invalidation
    /// prevents a stale source from closing a later, reused descriptor number.
    func finishReaderAndClose(registeredDescriptor: Int32) {
        var descriptorToClose: Int32 = -1
        var shouldComplete = false
        var continuations: [AsyncStream<PseudoTerminalOutput>.Continuation] = []
        lock.lock()
        if masterFileDescriptor == registeredDescriptor {
            descriptorToClose = masterFileDescriptor
            masterFileDescriptor = -1
        }
        if !readerFinished {
            readerFinished = true
            shouldComplete = true
            continuations = Array(outputSubscribers.values)
            outputSubscribers.removeAll()
        }
        lock.unlock()
        if descriptorToClose >= 0 { Darwin.close(descriptorToClose) }
        if shouldComplete { completionGroup.leave() }
        for continuation in continuations { continuation.finish() }
    }

    func output(offset: Int64, maxBytes: Int) -> PseudoTerminalRingRead? {
        lock.lock()
        defer { lock.unlock() }
        return ring.read(offset: offset, maxBytes: maxBytes)
    }

    func outputBounds() -> PseudoTerminalOutputBounds {
        lock.lock()
        defer { lock.unlock() }
        return ring.bounds
    }

    func outputEvents() -> AsyncStream<PseudoTerminalOutput> {
        let subscriberID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(256)) { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            lock.lock()
            if readerFinished {
                lock.unlock()
                continuation.finish()
                return
            }
            outputSubscribers[subscriberID] = continuation
            lock.unlock()
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.removeOutputSubscriber(subscriberID)
            }
        }
    }

    func status() -> PseudoTerminalStatus {
        lock.lock()
        defer { lock.unlock() }
        let state: PseudoTerminalState
        let exitCode: Int32?
        let terminationSignal: Int32?
        if let waitStatus {
            if waitStatus.kind == LumaPTYWaitKindExited {
                state = stopped ? .stopped : .exited
                exitCode = Int32(waitStatus.code)
                terminationSignal = nil
            } else if waitStatus.kind == LumaPTYWaitKindSignaled {
                state = stopped ? .stopped : .exited
                terminationSignal = Int32(waitStatus.code)
                exitCode = 128 + Int32(waitStatus.code)
            } else {
                state = .failed
                exitCode = nil
                terminationSignal = nil
            }
        } else if waitErrorCode != nil || readerErrorCode != nil {
            state = .failed
            exitCode = nil
            terminationSignal = nil
        } else {
            state = .running
            exitCode = nil
            terminationSignal = nil
        }
        return PseudoTerminalStatus(
            id: id,
            processIdentifier: processIdentifier,
            state: state,
            exitCode: exitCode,
            terminationSignal: terminationSignal,
            dimensions: dimensions,
            startedAt: startedAt,
            duration: startedClock.duration(to: .now).timeInterval,
            transportErrorCode: waitErrorCode ?? readerErrorCode
        )
    }

    func isComplete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (waitStatus != nil || waitErrorCode != nil) && readerFinished
    }

    func waitForCompletion() async {
        await withCheckedContinuation { continuation in
            completionGroup.notify(queue: DispatchQueue.global(qos: .utility)) {
                continuation.resume()
            }
        }
    }

    func waitForCompletion(timeout: TimeInterval) async -> Bool {
        await Task.detached(priority: .utility) { [self] in
            blockingWaitForCompletion(timeout: timeout)
        }.value
    }

    func eventDescriptor() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return masterFileDescriptor >= 0 ? masterFileDescriptor : nil
    }

    private func closeMasterLocked() {
        guard masterFileDescriptor >= 0 else { return }
        Darwin.close(masterFileDescriptor)
        masterFileDescriptor = -1
    }

    private func publishWaitCompletionLocked() {
        guard !didPublishWaitCompletion else { return }
        didPublishWaitCompletion = true
        completionGroup.leave()
    }

    private func blockingWaitForCompletion(timeout: TimeInterval) -> Bool {
        completionGroup.wait(timeout: .now() + max(0, timeout)) == .success
    }

    private func removeOutputSubscriber(_ id: UUID) {
        lock.lock()
        outputSubscribers.removeValue(forKey: id)
        lock.unlock()
    }
}

/// Dispatch sources keep idle terminals asleep. The event handler drains until
/// EAGAIN, then returns to the kernel rather than polling every few milliseconds.
private final class PseudoTerminalReadPump: @unchecked Sendable {
    private let record: PseudoTerminalProcessRecord
    private let source: DispatchSourceRead
    private let registeredDescriptor: Int32
    private let lock = NSLock()
    private var didCancel = false

    init?(record: PseudoTerminalProcessRecord) {
        guard let descriptor = record.eventDescriptor() else { return nil }
        self.record = record
        registeredDescriptor = descriptor
        source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { [record] in
            record.finishReaderAndClose(registeredDescriptor: descriptor)
        }
        source.resume()
    }

    deinit { cancel() }

    func cancel() {
        lock.lock()
        guard !didCancel else {
            lock.unlock()
            return
        }
        didCancel = true
        lock.unlock()
        source.cancel()
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            lock.lock()
            let isCancelled = didCancel
            lock.unlock()
            if isCancelled { return }
            switch record.drainOnce(buffer: &buffer) {
            case .data:
                continue
            case .retry:
                return
            case .finished:
                cancel()
                return
            case .failed:
                record.requestSignal(SIGKILL)
                cancel()
                return
            }
        }
    }
}

/// NOTE_EXIT is edge-driven by the kernel. WNOWAIT/reap still happens inside
/// PseudoTerminalProcessRecord's lifecycle lock, preventing stale PID reuse.
private final class PseudoTerminalExitMonitor: @unchecked Sendable {
    private let record: PseudoTerminalProcessRecord
    private let source: DispatchSourceProcess
    private let lock = NSLock()
    private var didCancel = false
    private var keepAlive: PseudoTerminalExitMonitor?

    init(record: PseudoTerminalProcessRecord) {
        self.record = record
        source = DispatchSource.makeProcessSource(
            identifier: record.processIdentifier,
            eventMask: .exit,
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in self?.processDidExit() }
        source.resume()
        // The monitor, not the view/actor, owns the obligation to reap. This
        // self-retain is released only after a final wait status is published.
        keepAlive = self
        probeMissedExitEdge()
    }

    deinit { cancel() }

    func cancel() {
        lock.lock()
        guard !didCancel else {
            lock.unlock()
            return
        }
        didCancel = true
        lock.unlock()
        source.cancel()
        keepAlive = nil
    }

    private func processDidExit() {
        switch record.reapIfExited() {
        case .pending:
            // NOTE_EXIT may precede waitid visibility by a tiny interval. A
            // one-shot delayed retry is event fallout, not an idle poll loop.
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + .milliseconds(2)
            ) { [weak self] in self?.processDidExit() }
        case .completed, .failed:
            cancel()
        }
    }

    private func probeMissedExitEdge() {
        switch record.reapIfExited() {
        case .pending:
            return
        case .completed, .failed:
            cancel()
        }
    }
}

private final class PseudoTerminalCStringVector {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let strings: [UnsafeMutablePointer<CChar>]

    init(_ values: [String]) throws {
        var allocated: [UnsafeMutablePointer<CChar>] = []
        allocated.reserveCapacity(values.count)
        for value in values {
            guard !value.contains("\0"), let copy = strdup(value) else {
                for pointer in allocated { free(pointer) }
                throw PseudoTerminalError.invalidCommand
            }
            allocated.append(copy)
        }
        strings = allocated
        pointer = .allocate(capacity: values.count + 1)
        for (index, string) in strings.enumerated() { pointer[index] = string }
        pointer[values.count] = nil
    }

    deinit {
        for string in strings { free(string) }
        pointer.deallocate()
    }
}

/// A single real pseudo-terminal transport. Task terminal management and
/// rendering live above this actor; this layer owns only the process/TTY bytes,
/// size, cancellation, reaping, and bounded in-memory scrollback.
actor PseudoTerminalSession {
    static let maximumInputBytes = 64 * 1_024
    static let maximumReadBytes = 1 * 1_024 * 1_024
    static let maximumCommandBytes = 256 * 1_024
    static let defaultScrollbackBytes = 2 * 1_024 * 1_024

    private let validator: WorkspaceSecurityValidator
    private let sandbox: any AgentSandboxPolicy
    private let initialDirectory: URL
    private let sessionEnvironment: [String: String]
    private let scrollbackBytes: Int
    private let riskAnalyzer = CommandRiskAnalyzer()
    private var record: PseudoTerminalProcessRecord?
    private var readPump: PseudoTerminalReadPump?
    private var exitMonitor: PseudoTerminalExitMonitor?
    private var isDisposed = false

    init(
        validator: WorkspaceSecurityValidator,
        cwd: String? = nil,
        environment: [String: String] = [:],
        scrollbackBytes: Int = PseudoTerminalSession.defaultScrollbackBytes,
        sandboxBackend: any SandboxBackend = MacOSSandboxBackend()
    ) throws {
        self.validator = validator
        do {
            initialDirectory = try validator.validate(cwd: cwd)
        } catch {
            throw PseudoTerminalError.workspaceBoundary(cwd ?? ".")
        }
        // Reject an invalid cwd before allocating sandbox runtime directories.
        // If the independently constructed sandbox ever disagrees with the
        // validator, remove its disposable runtime before failing closed.
        let createdSandbox = try sandboxBackend.makeWorkspacePolicy(
            validator: validator,
            additionalReadOnlyRoots: []
        )
        guard createdSandbox.containsWorkspacePath(initialDirectory) else {
            let runtime = createdSandbox.runtimeEnvironment.root.standardizedFileURL
            let parent = AppPaths.agentProcesses.standardizedFileURL
            if runtime.path.hasPrefix(parent.path + "/") {
                try? FileManager.default.removeItem(at: runtime)
            }
            throw PseudoTerminalError.workspaceBoundary(initialDirectory.path)
        }
        sandbox = createdSandbox
        sessionEnvironment = environment
        self.scrollbackBytes = min(max(4_096, scrollbackBytes), 16 * 1_024 * 1_024)
    }

    deinit {
        readPump?.cancel()
        // requestSignal is lifecycle-locked against WNOWAIT/reap and becomes a
        // no-op after final status publication. This RAII fallback therefore
        // cannot target a reused PID, while still terminating a child whose
        // owner forgot to call dispose(). The detached waiter keeps the record
        // alive long enough to reap it.
        let orphanedRecord = record
        orphanedRecord?.requestSignal(SIGKILL)
        if readPump == nil { orphanedRecord?.closeMaster() }
        let runtime = sandbox.runtimeEnvironment.root.standardizedFileURL
        let parent = AppPaths.agentProcesses.standardizedFileURL
        // The PTY child inherits TMPDIR/HOME below this runtime. Do not remove
        // it until the cancellation handler has closed the master and the exit
        // monitor has reaped the child. This detached fallback is bounded and
        // captures no actor-isolated state.
        if runtime.path.hasPrefix(parent.path + "/") {
            Task.detached(priority: .utility) {
                if let orphanedRecord {
                    _ = await orphanedRecord.waitForCompletion(timeout: 4)
                }
                try? FileManager.default.removeItem(at: runtime)
            }
        }
    }

    func start(
        command: String? = nil,
        cwd: String? = nil,
        environment commandEnvironment: [String: String] = [:],
        shell: String = "/bin/zsh",
        rows: Int = 24,
        columns: Int = 80,
        allowsNetwork: Bool = false,
        allowsGitMetadata: Bool = false,
        allowsGitMetadataWrite: Bool = false
    ) throws -> PseudoTerminalStatus {
        guard !isDisposed else { throw PseudoTerminalError.disposed }
        guard record == nil else { throw PseudoTerminalError.alreadyStarted }
        guard ["/bin/zsh", "/bin/bash", "/bin/sh"].contains(shell) else {
            throw PseudoTerminalError.invalidShell(shell)
        }
        guard (1...1_000).contains(rows), (1...1_000).contains(columns) else {
            throw PseudoTerminalError.invalidDimensions
        }
        let actualCommand = command ?? "exec \(shell) -il"
        guard !actualCommand.isEmpty,
              !actualCommand.contains("\0"),
              actualCommand.utf8.count <= Self.maximumCommandBytes else {
            throw PseudoTerminalError.invalidCommand
        }

        let workingDirectory: URL
        do {
            workingDirectory = try cwd.map { try validator.validate(cwd: $0) }
                ?? initialDirectory
        } catch {
            throw PseudoTerminalError.workspaceBoundary(cwd ?? ".")
        }
        guard sandbox.containsWorkspacePath(workingDirectory) else {
            throw PseudoTerminalError.workspaceBoundary(workingDirectory.path)
        }

        let assessment = riskAnalyzer.assess(actualCommand)
        let executable = sandbox.pseudoTerminalLauncherExecutable.path
        let arguments = [executable] + sandbox.pseudoTerminalLauncherArguments(
            command: actualCommand,
            shell: shell,
            allowsNetwork: allowsNetwork || assessment.usesNetwork,
            allowsGitMetadata: allowsGitMetadata,
            allowsGitMetadataWrite: allowsGitMetadataWrite,
            allowsWorkspaceWrite: true
        )
        var environment = sandbox.environment(
            session: sessionEnvironment,
            command: commandEnvironment
        )
        environment["TERM"] = environment["TERM"] ?? "xterm-256color"
        environment["COLORTERM"] = environment["COLORTERM"] ?? "truecolor"
        environment["LUMACHAT_PTY"] = "1"
        let environmentValues = environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        let argumentVector = try PseudoTerminalCStringVector(arguments)
        let environmentVector = try PseudoTerminalCStringVector(environmentValues)
        var process = LumaPTYProcess(process_identifier: -1, master_file_descriptor: -1)
        var spawnError = LumaPTYSpawnError(stage: LumaPTYSpawnStageNone, error_number: 0)
        let dimensions = PseudoTerminalDimensions(
            rows: UInt16(rows),
            columns: UInt16(columns)
        )
        let spawnResult = executable.withCString { executablePointer in
            workingDirectory.path.withCString { directoryPointer in
                var options = LumaPTYSpawnOptions(
                    executable_path: executablePointer,
                    arguments: argumentVector.pointer,
                    environment: environmentVector.pointer,
                    working_directory: directoryPointer,
                    rows: dimensions.rows,
                    columns: dimensions.columns,
                    pixel_width: 0,
                    pixel_height: 0
                )
                return luma_pty_spawn(&options, &process, &spawnError)
            }
        }
        guard spawnResult == 0 else {
            throw PseudoTerminalError.spawnFailed(
                stage: Int32(spawnError.stage.rawValue),
                errorCode: Int32(spawnError.error_number)
            )
        }

        let newRecord = PseudoTerminalProcessRecord(
            process: process,
            dimensions: dimensions,
            capacity: scrollbackBytes
        )
        record = newRecord
        // Install the process exit monitor before any later setup can fail so
        // every successfully forked child has a self-retaining reaper.
        exitMonitor = PseudoTerminalExitMonitor(record: newRecord)
        guard let pump = PseudoTerminalReadPump(record: newRecord) else {
            newRecord.requestSignal(SIGKILL)
            newRecord.closeMaster()
            throw PseudoTerminalError.operationFailed(
                operation: "readiness source",
                errorCode: EBADF
            )
        }
        readPump = pump
        return newRecord.status()
    }

    func status() throws -> PseudoTerminalStatus {
        guard let record else { throw PseudoTerminalError.notStarted }
        return record.status()
    }

    func readOutput(
        offset: Int64 = 0,
        maxBytes: Int = 64 * 1_024
    ) throws -> PseudoTerminalOutput {
        guard let record else { throw PseudoTerminalError.notStarted }
        guard offset >= 0 else { throw PseudoTerminalError.invalidOutputOffset(offset) }
        let boundedMaximum = min(max(1, maxBytes), Self.maximumReadBytes)
        guard let output = record.output(offset: offset, maxBytes: boundedMaximum) else {
            throw PseudoTerminalError.invalidOutputOffset(offset)
        }
        return PseudoTerminalOutput(
            id: record.id,
            data: output.data,
            offset: output.offset,
            nextOffset: output.nextOffset,
            earliestAvailableOffset: output.earliestOffset,
            hasMore: output.hasMore,
            truncatedBeforeOffset: output.truncatedBeforeOffset
        )
    }

    func outputBounds() throws -> PseudoTerminalOutputBounds {
        guard let record else { throw PseudoTerminalError.notStarted }
        return record.outputBounds()
    }

    func outputEvents() throws -> AsyncStream<PseudoTerminalOutput> {
        guard let record else { throw PseudoTerminalError.notStarted }
        return record.outputEvents()
    }

    func write(_ data: Data) async throws -> PseudoTerminalWriteResult {
        try Task.checkCancellation()
        guard let record else { throw PseudoTerminalError.notStarted }
        guard !data.isEmpty, data.count <= Self.maximumInputBytes else {
            throw PseudoTerminalError.inputTooLarge(maxBytes: Self.maximumInputBytes)
        }
        guard record.status().state == .running else { throw PseudoTerminalError.notRunning }
        guard record.beginWrite() else { throw PseudoTerminalError.inputBusy }
        defer { record.endWrite() }

        let started = ContinuousClock.now
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            switch record.write(data, offset: offset) {
            case .success(let count):
                if count > 0 {
                    offset += count
                } else if started.duration(to: .now) >= .seconds(2) {
                    throw PseudoTerminalError.inputBackpressure(bytesWritten: offset)
                } else {
                    try await Task.sleep(for: .milliseconds(5))
                }
            case .failure(let errorCode) where errorCode == EINTR:
                continue
            case .failure(let errorCode)
                where errorCode == EAGAIN || errorCode == EWOULDBLOCK:
                guard started.duration(to: .now) < .seconds(2) else {
                    throw PseudoTerminalError.inputBackpressure(bytesWritten: offset)
                }
                try await Task.sleep(for: .milliseconds(5))
            case .failure(let errorCode) where errorCode == EIO || errorCode == EBADF
                || errorCode == EPIPE || errorCode == ESRCH:
                throw PseudoTerminalError.notRunning
            case .failure(let errorCode):
                throw PseudoTerminalError.operationFailed(
                    operation: "write",
                    errorCode: errorCode
                )
            }
        }
        return PseudoTerminalWriteResult(id: record.id, bytesWritten: offset)
    }

    func write(text: String) async throws -> PseudoTerminalWriteResult {
        try await write(Data(text.utf8))
    }

    func sendEndOfTransmission() async throws -> PseudoTerminalWriteResult {
        try await write(Data([0x04]))
    }

    func resize(rows: Int, columns: Int) throws -> PseudoTerminalStatus {
        guard (1...1_000).contains(rows), (1...1_000).contains(columns) else {
            throw PseudoTerminalError.invalidDimensions
        }
        guard let record else { throw PseudoTerminalError.notStarted }
        let dimensions = PseudoTerminalDimensions(
            rows: UInt16(rows),
            columns: UInt16(columns)
        )
        if let errorCode = record.resize(dimensions) {
            if errorCode == ESRCH || errorCode == EIO || errorCode == EBADF {
                throw PseudoTerminalError.notRunning
            }
            throw PseudoTerminalError.operationFailed(
                operation: "resize",
                errorCode: errorCode
            )
        }
        return record.status()
    }

    /// Delivers one explicitly allowed terminal signal to the current
    /// foreground job as well as the original PTY session group. The service
    /// layer exposes only a small named allow-list; arbitrary signal numbers
    /// never cross the model/UI boundary.
    func signal(_ signal: Int32) throws -> PseudoTerminalStatus {
        guard [SIGINT, SIGQUIT, SIGHUP, SIGTERM, SIGKILL, SIGTSTP, SIGCONT]
            .contains(signal) else {
            throw PseudoTerminalError.operationFailed(
                operation: "signal",
                errorCode: EINVAL
            )
        }
        guard let record else { throw PseudoTerminalError.notStarted }
        guard record.status().state == .running else {
            throw PseudoTerminalError.notRunning
        }
        record.requestSignal(signal)
        return record.status()
    }

    func waitForExit() async throws -> PseudoTerminalStatus {
        guard let record else { throw PseudoTerminalError.notStarted }
        try Task.checkCancellation()
        await record.waitForCompletion()
        try Task.checkCancellation()
        return record.status()
    }

    func stop() async throws -> PseudoTerminalStatus {
        guard let record else { throw PseudoTerminalError.notStarted }
        if record.status().state == .running {
            record.requestStop()
            let started = ContinuousClock.now
            while record.status().state == .running,
                  started.duration(to: .now) < .seconds(2) {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if record.status().state == .running {
                record.requestSignal(SIGKILL)
            }
        }
        if await record.waitForCompletion(timeout: 3) == false {
            record.requestSignal(SIGKILL)
            readPump?.cancel()
            _ = await record.waitForCompletion(timeout: 1)
        }
        return record.status()
    }

    func dispose() async {
        guard !isDisposed else { return }
        isDisposed = true
        if record != nil { _ = try? await stop() }
        readPump?.cancel()
        if readPump == nil { record?.closeMaster() }
        if let record { _ = await record.waitForCompletion(timeout: 1) }
        readPump = nil
        // Exit monitor self-retains until it publishes wait status/reaps. Only
        // release this actor's reference after bounded cleanup has completed.
        exitMonitor = nil
        let runtime = sandbox.runtimeEnvironment.root.standardizedFileURL
        let parent = AppPaths.agentProcesses.standardizedFileURL
        if runtime.path.hasPrefix(parent.path + "/") {
            try? FileManager.default.removeItem(at: runtime)
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
