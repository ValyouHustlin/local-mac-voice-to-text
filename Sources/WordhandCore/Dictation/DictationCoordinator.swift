import Foundation

public enum HotkeyEvent: Equatable, Sendable {
    case pressed
    case released
}

public enum DictationFailure: Equatable, Sendable {
    case capture(String)
    case transcription(String)
    case history(String)
    case historyStatus(String)
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
    func stop() async -> [Float]
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
    public var onHistoryChange: (() -> Void)?

    private let capture: AudioCapturing
    private let transcriber: Transcribing
    private let processor: TranscriptProcessing
    private let inserter: TextInserting
    private let history: TranscriptRecording?
    private var insertionMode: InsertionMode
    private let language: String?
    private let audioSampleRate: Double
    private let currentTarget: () -> TranscriptTarget
    private let date: () -> Date
    private let now: () -> TimeInterval

    public init(
        capture: AudioCapturing,
        transcriber: Transcribing,
        processor: TranscriptProcessing,
        inserter: TextInserting,
        history: TranscriptRecording? = nil,
        insertionMode: InsertionMode = .unicode,
        language: String? = nil,
        audioSampleRate: Double = 16_000,
        currentTarget: @escaping () -> TranscriptTarget = { .unknown },
        date: @escaping () -> Date = Date.init,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.capture = capture
        self.transcriber = transcriber
        self.processor = processor
        self.inserter = inserter
        self.history = history
        self.insertionMode = insertionMode
        self.language = language
        self.audioSampleRate = audioSampleRate
        self.currentTarget = currentTarget
        self.date = date
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
            let samples = await capture.stop()
            onCapture?(samples)
            guard !samples.isEmpty else {
                state = .idle
                return
            }

            state = .transcribing
            let transcriptionStarted = now()
            let raw: String
            do {
                raw = try await transcriber.transcribe(samples)
            } catch {
                state = .failed(.transcription(String(describing: error)))
                return
            }

            let transcriptionElapsed = now() - transcriptionStarted
            state = .processing
            let text = processor.process(raw)
            guard !text.isEmpty else {
                state = .idle
                return
            }

            let record = TranscriptRecord(
                createdAt: date(),
                rawText: raw,
                text: text,
                modelID: transcriber.modelID,
                language: language,
                audioDuration: Double(samples.count) / audioSampleRate,
                transcriptionDuration: transcriptionElapsed,
                insertionMode: insertionMode,
                target: currentTarget(),
                status: .pendingInsertion
            )
            if let history {
                do {
                    try history.save(record)
                    onHistoryChange?()
                } catch {
                    state = .failed(.history(String(describing: error)))
                    return
                }
            }
            onTranscript?(text, transcriptionElapsed)

            state = .inserting
            do {
                try await inserter.insert(text, mode: insertionMode)
            } catch {
                if let history {
                    try? history.updateStatus(
                        id: record.id,
                        status: .insertionFailed(String(describing: error))
                    )
                    onHistoryChange?()
                }
                state = .failed(.insertion(String(describing: error)))
                return
            }

            if let history {
                do {
                    try history.updateStatus(id: record.id, status: .inserted)
                    onHistoryChange?()
                } catch {
                    state = .failed(.historyStatus(String(describing: error)))
                    return
                }
            }
            state = .idle
        }
    }

    public func resetFailure() {
        guard case .failed = state else { return }
        state = .idle
    }

    public func updateInsertionMode(_ insertionMode: InsertionMode) {
        self.insertionMode = insertionMode
    }
}
