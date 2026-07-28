import Foundation

public enum HotkeyEvent: Sendable {
    case pressed
    case released
}

public enum DictationFailure: Equatable, Sendable {
    case capture(String)
    case transcription(String)
    case insertion(String)
}

public enum DictationState: Equatable, Sendable {
    case idle
    case recording
    case transcribing
    case processing
    case inserting
    case failed(DictationFailure)
}

public protocol AudioCapturing: AnyObject {
    func start() throws
    func stop() -> [Float]
}

public protocol HotkeyMonitoring: AnyObject {
    func start(onEvent: @escaping (HotkeyEvent) -> Void) throws
    func stop()
}

public protocol Transcribing: Sendable {
    var modelID: String { get }
    func warmUp() async throws
    func transcribe(_ audio: [Float]) async throws -> String
}

public protocol TranscriptProcessing: Sendable {
    func process(_ text: String) -> String
}

public protocol TextInserting: Sendable {
    func insert(_ text: String, mode: InsertionMode) async throws
}

@MainActor
public final class DictationCoordinator {
    public private(set) var state: DictationState = .idle {
        didSet { onStateChange?(state) }
    }

    public var onStateChange: ((DictationState) -> Void)?
    public var onCapture: (([Float]) -> Void)?
    public var onTranscript: ((String, TimeInterval) -> Void)?

    private let capture: AudioCapturing
    private let transcriber: Transcribing
    private let processor: TranscriptProcessing
    private let inserter: TextInserting
    private let insertionMode: InsertionMode
    private let now: () -> TimeInterval

    public init(
        capture: AudioCapturing,
        transcriber: Transcribing,
        processor: TranscriptProcessing,
        inserter: TextInserting,
        insertionMode: InsertionMode = .unicode,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.capture = capture
        self.transcriber = transcriber
        self.processor = processor
        self.inserter = inserter
        self.insertionMode = insertionMode
        self.now = now
    }

    public func handle(_ event: HotkeyEvent) async {
        switch event {
        case .pressed:
            if case .failed = state {
                state = .idle
            }
            guard state == .idle else { return }
            do {
                try capture.start()
                state = .recording
            } catch {
                state = .failed(.capture(String(describing: error)))
            }

        case .released:
            guard state == .recording else { return }
            let samples = capture.stop()
            onCapture?(samples)
            guard !samples.isEmpty else {
                state = .idle
                return
            }

            state = .transcribing
            do {
                let transcriptionStarted = now()
                let raw = try await transcriber.transcribe(samples)
                let transcriptionElapsed = now() - transcriptionStarted
                state = .processing
                let text = processor.process(raw)
                guard !text.isEmpty else {
                    state = .idle
                    return
                }
                state = .inserting
                try await inserter.insert(text, mode: insertionMode)
                onTranscript?(text, transcriptionElapsed)
                state = .idle
            } catch {
                if state == .inserting {
                    state = .failed(.insertion(String(describing: error)))
                } else {
                    state = .failed(.transcription(String(describing: error)))
                }
            }
        }
    }

    public func resetFailure() {
        guard case .failed = state else { return }
        state = .idle
    }
}
