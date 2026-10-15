import Foundation
import XCTest
@testable import LumaChat

@MainActor
private final class VoiceAuthorizationFixture: TaskVoiceAuthorizing {
    var speech: Bool
    var microphone: Bool
    var deferredSpeech = false
    private(set) var pendingSpeech: CheckedContinuation<Bool, Never>?

    init(speech: Bool, microphone: Bool) {
        self.speech = speech
        self.microphone = microphone
    }

    func speechAllowed() async -> Bool {
        if deferredSpeech {
            return await withCheckedContinuation { pendingSpeech = $0 }
        }
        return speech
    }

    func microphoneAllowed() async -> Bool { microphone }

    func releaseSpeech() {
        pendingSpeech?.resume(returning: speech)
        pendingSpeech = nil
    }
}

@MainActor
private final class VoiceCaptureFixture: TaskVoiceCapturing {
    var receivers: [@Sendable (TaskVoiceRecognitionEvent) -> Void] = []
    private(set) var running = false
    func start(_ receive: @escaping @Sendable (TaskVoiceRecognitionEvent) -> Void) throws {
        receivers.append(receive)
        running = true
    }
    func stop() { running = false }
}

@MainActor
private final class VoiceSpeechFixture: TaskVoiceSpeaking {
    var completions: [@MainActor () -> Void] = []
    private(set) var running = false
    func speak(_ text: String, completion: @escaping @MainActor () -> Void) {
        completions.append(completion)
        running = true
    }
    func stop() { running = false }
}

@MainActor
final class TaskVoiceProviderTests: XCTestCase {
    func testAutomaticPlaybackOnlyUsesNewReplyFromOriginalTask() {
        var session = AgentSession(mode: .agent)
        session.messages = [AgentMessage(role: .assistant, content: "old answer")]
        let anchor = TaskVoiceReplyAnchor(session: session)
        session.state = .failed
        XCTAssertNil(anchor.reply(in: session))
        session.messages.append(AgentMessage(role: .assistant, content: "new answer"))
        session.state = .running
        XCTAssertNil(anchor.reply(in: session))
        session.state = .completed
        XCTAssertEqual(anchor.reply(in: session), "new answer")
        session.id = UUID()
        XCTAssertNil(anchor.reply(in: session))
    }

    func testOldRecognitionCallbackCannotStopNewCaptureAndFinalTextCanBeSubmittedOnce() async throws {
        let capture = VoiceCaptureFixture()
        let provider = SystemTaskVoiceProvider(
            authorization: VoiceAuthorizationFixture(speech: true, microphone: true),
            capture: capture, speech: VoiceSpeechFixture()
        )
        try await provider.startListening()
        _ = provider.stopListening()
        try await provider.startListening()
        capture.receivers[0](TaskVoiceRecognitionEvent(text: "stale", failed: true))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(provider.isListening)
        XCTAssertTrue(capture.running)
        XCTAssertEqual(provider.transcript, "")
        XCTAssertNil(provider.errorMessage)

        capture.receivers[1](TaskVoiceRecognitionEvent(text: "new final text", isFinal: true))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(provider.isListening)
        XCTAssertFalse(capture.running)
        XCTAssertEqual(provider.transcript, "new final text")
        XCTAssertEqual(provider.stopListening(), "new final text")
        XCTAssertEqual(provider.stopListening(), "")
    }

    func testPlaybackStopsCaptureAndOldPlaybackCompletionCannotStopNewSpeech() async throws {
        let capture = VoiceCaptureFixture()
        let speech = VoiceSpeechFixture()
        let provider = SystemTaskVoiceProvider(
            authorization: VoiceAuthorizationFixture(speech: true, microphone: true),
            capture: capture, speech: speech
        )
        try await provider.startListening()
        provider.speak("first")
        XCTAssertFalse(capture.running)
        XCTAssertFalse(provider.isListening)
        provider.speak("second")
        speech.completions[0]()
        XCTAssertTrue(provider.isSpeaking)
        speech.completions[1]()
        XCTAssertFalse(provider.isSpeaking)
    }

    func testDeniedPermissionsLeaveMicrophoneStopped() async throws {
        let speechDenied = SystemTaskVoiceProvider(
            authorization: VoiceAuthorizationFixture(speech: false, microphone: true)
        )
        do {
            try await speechDenied.startListening()
            XCTFail("Speech denial must stop before microphone access")
        } catch TaskVoiceError.recognitionDenied {}
        XCTAssertFalse(speechDenied.isListening)

        let microphoneDenied = SystemTaskVoiceProvider(
            authorization: VoiceAuthorizationFixture(speech: true, microphone: false)
        )
        do {
            try await microphoneDenied.startListening()
            XCTFail("Microphone denial must stop before capture")
        } catch TaskVoiceError.microphoneDenied {}
        XCTAssertFalse(microphoneDenied.isListening)
    }

    func testStopWhileAuthorizationIsPendingPreventsCapture() async throws {
        let authorization = VoiceAuthorizationFixture(speech: true, microphone: true)
        authorization.deferredSpeech = true
        let provider = SystemTaskVoiceProvider(authorization: authorization)
        let start = Task { try await provider.startListening() }
        for _ in 0..<100 where authorization.pendingSpeech == nil {
            await Task.yield()
        }
        XCTAssertNotNil(authorization.pendingSpeech)
        XCTAssertEqual(provider.stopListening(), "")
        authorization.releaseSpeech()
        try await start.value
        XCTAssertFalse(provider.isListening)
        provider.stopSpeaking()
        XCTAssertFalse(provider.isSpeaking)
    }
}
