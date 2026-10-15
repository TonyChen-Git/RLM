import AVFoundation
import Combine
import Foundation
import Speech

enum TaskVoiceError: LocalizedError, Sendable {
    case microphoneDenied
    case recognitionDenied
    case onDeviceUnavailable
    case unavailable

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "麥克風權限未開啟；可繼續使用文字輸入。"
        case .recognitionDenied: "語音辨識權限未開啟；可繼續使用文字輸入。"
        case .onDeviceUnavailable: "此語言的系統離線語音辨識不可用；可改用文字輸入。"
        case .unavailable: "語音裝置目前無法使用；可改用文字輸入。"
        }
    }
}

@MainActor
protocol TaskVoiceProviding: AnyObject {
    var transcript: String { get }
    var isListening: Bool { get }
    var isSpeaking: Bool { get }
    func startListening() async throws
    func stopListening() -> String
    func speak(_ text: String)
    func stopSpeaking()
}

@MainActor
protocol TaskVoiceAuthorizing: AnyObject {
    func speechAllowed() async -> Bool
    func microphoneAllowed() async -> Bool
}

@MainActor
final class SystemTaskVoiceAuthorization: TaskVoiceAuthorizing {
    func speechAllowed() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { value in
                continuation.resume(returning: value == .authorized)
            }
        }
    }

    func microphoneAllowed() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { value in
                continuation.resume(returning: value)
            }
        }
    }
}

struct TaskVoiceRecognitionEvent: Sendable {
    var text: String?
    var isFinal: Bool = false
    var failed: Bool = false
}

/// Automatic playback is bound to the submission that requested it. A failed
/// turn must not read an older answer, and navigation must not read another Task.
struct TaskVoiceReplyAnchor: Sendable {
    let taskID: UUID
    let previousMessageIDs: Set<UUID>

    init(session: AgentSession) {
        taskID = session.id
        previousMessageIDs = Set(session.messages.map(\.id))
    }

    func reply(in session: AgentSession) -> String? {
        guard session.id == taskID,
              [.completed, .paused, .stepLimit, .failed].contains(session.state) else { return nil }
        return session.messages.last(where: {
            $0.role == .assistant && !previousMessageIDs.contains($0.id)
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.content
    }
}

@MainActor
protocol TaskVoiceCapturing: AnyObject {
    func start(_ receive: @escaping @Sendable (TaskVoiceRecognitionEvent) -> Void) throws
    func stop()
}

@MainActor
protocol TaskVoiceSpeaking: AnyObject {
    func speak(_ text: String, completion: @escaping @MainActor () -> Void)
    func stop()
}

/// Audio buffers remain in memory. The capture implementation never falls
/// back to server recognition when on-device recognition is unavailable.
@MainActor
final class SystemTaskVoiceCapture: TaskVoiceCapturing {
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapInstalled = false

    func start(_ receive: @escaping @Sendable (TaskVoiceRecognitionEvent) -> Void) throws {
        stop()
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current),
              recognizer.isAvailable else { throw TaskVoiceError.unavailable }
        guard recognizer.supportsOnDeviceRecognition else {
            throw TaskVoiceError.onDeviceUnavailable
        }
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            throw TaskVoiceError.unavailable
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        recognitionRequest = request
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        tapInstalled = true
        recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            receive(TaskVoiceRecognitionEvent(
                text: result?.bestTranscription.formattedString,
                isFinal: result?.isFinal == true,
                failed: error != nil
            ))
        }
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            stop()
            throw TaskVoiceError.unavailable
        }
    }

    func stop() {
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }
}

@MainActor
final class SystemTaskVoiceSpeech: NSObject, TaskVoiceSpeaking, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var activeUtterance: ObjectIdentifier?
    private var completion: (@MainActor () -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, completion: @escaping @MainActor () -> Void) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
        activeUtterance = ObjectIdentifier(utterance)
        self.completion = completion
        synthesizer.speak(utterance)
    }

    func stop() {
        activeUtterance = nil
        completion = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        finished(ObjectIdentifier(utterance))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        finished(ObjectIdentifier(utterance))
    }

    private nonisolated func finished(_ identifier: ObjectIdentifier) {
        Task { @MainActor [weak self] in
            guard let self, self.activeUtterance == identifier else { return }
            let completion = self.completion
            self.activeUtterance = nil
            self.completion = nil
            completion?()
        }
    }
}

@MainActor
final class SystemTaskVoiceProvider: ObservableObject, TaskVoiceProviding {
    @Published private(set) var transcript = ""
    @Published private(set) var isStarting = false
    @Published private(set) var isListening = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var errorMessage: String?

    private let authorization: any TaskVoiceAuthorizing
    private let capture: any TaskVoiceCapturing
    private let speech: any TaskVoiceSpeaking
    private var requestGeneration = 0
    private var speechGeneration = 0

    init(authorization: any TaskVoiceAuthorizing = SystemTaskVoiceAuthorization(),
         capture: any TaskVoiceCapturing = SystemTaskVoiceCapture(),
         speech: any TaskVoiceSpeaking = SystemTaskVoiceSpeech()) {
        self.authorization = authorization
        self.capture = capture
        self.speech = speech
    }

    func startListening() async throws {
        guard !isListening, !isStarting else { return }
        stopSpeaking()
        requestGeneration &+= 1
        let generation = requestGeneration
        isStarting = true
        defer { if generation == requestGeneration { isStarting = false } }
        transcript = ""
        errorMessage = nil
        let speechPermission = await authorization.speechAllowed()
        guard generation == requestGeneration, !Task.isCancelled else { return }
        guard speechPermission else { throw TaskVoiceError.recognitionDenied }
        let microphonePermission = await authorization.microphoneAllowed()
        guard generation == requestGeneration, !Task.isCancelled else { return }
        guard microphonePermission else { throw TaskVoiceError.microphoneDenied }
        isListening = true
        do {
            try capture.start { [weak self] event in
                Task { @MainActor [weak self] in
                    guard let self, self.requestGeneration == generation, self.isListening else { return }
                    if let text = event.text { self.transcript = String(text.prefix(16_384)) }
                    if event.failed { self.errorMessage = TaskVoiceError.unavailable.localizedDescription }
                    if event.failed || event.isFinal {
                        self.requestGeneration &+= 1
                        self.isListening = false
                        self.capture.stop()
                    }
                }
            }
        } catch {
            requestGeneration &+= 1
            isStarting = false
            isListening = false
            capture.stop()
            throw error
        }
    }

    @discardableResult
    func stopListening() -> String {
        requestGeneration &+= 1
        isStarting = false
        isListening = false
        capture.stop()
        let value = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = ""
        return value
    }

    func speak(_ text: String) {
        _ = stopListening()
        stopSpeaking()
        let bounded = String(text.prefix(16_384)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bounded.isEmpty else { return }
        let generation = speechGeneration
        isSpeaking = true
        speech.speak(bounded) { [weak self] in
            guard let self, self.speechGeneration == generation else { return }
            self.isSpeaking = false
        }
    }

    func stopSpeaking() {
        speechGeneration &+= 1
        isSpeaking = false
        speech.stop()
    }
}
