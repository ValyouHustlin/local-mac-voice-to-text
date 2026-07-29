import AVFoundation
import Foundation
import Speech
import WordhandCore
import WordhandMobileCore

@MainActor
final class RecorderViewModel: ObservableObject {
    enum EngineCandidate: String, CaseIterable, Identifiable {
        case appleSpeech
        case whisperLarge

        var id: String { rawValue }

        var name: String {
            switch self {
            case .appleSpeech:
                return "Apple on device"
            case .whisperLarge:
                return "Whisper Large v3"
            }
        }

        var detail: String {
            switch self {
            case .appleSpeech:
                return "Uses the speech model already on your iPhone."
            case .whisperLarge:
                return "Highest accuracy candidate. Downloads 626 MB once."
            }
        }
    }

    enum State: Equatable {
        case preparing
        case authorizing
        case ready
        case recording
        case transcribing
        case readyInKeyboard(String)
        case failed(String)
    }

    @Published private(set) var state: State = .preparing
    @Published private(set) var latestTranscript = ""
    @Published private(set) var selectedEngine: EngineCandidate = .appleSpeech

    let localeIdentifier = "en_US"
    private let recorder = LocalAudioRecorder()
    private var transcriber: any AudioFileTranscribing
    private var shouldStartAfterPreparation = false

    init(transcriber: any AudioFileTranscribing = OnDeviceSpeechTranscriber()) {
        self.transcriber = transcriber
    }

    var isRecording: Bool {
        state == .recording
    }

    func prepare() async {
        guard state == .preparing else { return }
        state = .authorizing
        guard await requestPermissions() else {
            state = .failed(
                "Wordhand needs Microphone and Speech Recognition access. Both remain on this iPhone."
            )
            return
        }
        state = .ready
        if shouldStartAfterPreparation {
            shouldStartAfterPreparation = false
            await startRecording()
        }
    }

    func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    func selectEngine(_ engine: EngineCandidate) {
        guard !isRecording, state != .transcribing else { return }
        selectedEngine = engine
        switch engine {
        case .appleSpeech:
            transcriber = OnDeviceSpeechTranscriber()
        case .whisperLarge:
            // Selecting this option is the explicit consent for WhisperKit to
            // download only the named model assets if they are not on device.
            transcriber = WhisperKitAudioFileTranscriber(allowModelDownload: true)
        }
    }

    func startRecording() async {
        if state == .preparing {
            shouldStartAfterPreparation = true
            await prepare()
            return
        }
        if state == .authorizing {
            shouldStartAfterPreparation = true
            return
        }
        guard state == .ready || {
            if case .readyInKeyboard = state { return true }
            if case .failed = state { return true }
            return false
        }() else {
            return
        }

        do {
            let benchmarkStore = try MobileConfiguration.benchmarkStore()
            let id = UUID()
            let url = try benchmarkStore.audioFileURL(id: id)
            try recorder.start(fileURL: url, id: id)
            latestTranscript = ""
            state = .recording
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stopRecording() async {
        guard isRecording else { return }
        do {
            let recording = try recorder.stop()
            state = .transcribing
            let thermalStateBefore = ProcessInfo.processInfo.thermalState.wordhandName
            let result = try await transcriber.transcribe(
                audioFileURL: recording.fileURL,
                localeIdentifier: localeIdentifier
            )
            let sharedStore = try MobileConfiguration.sharedTranscriptStore()
            let pipeline = MobileTranscriptPipeline(store: sharedStore)
            let draft = try pipeline.processAndSave(result.text)
            latestTranscript = draft.text

            let observation = TranscriptionObservation(
                id: recording.id,
                engineID: result.engineID,
                localeIdentifier: result.localeIdentifier,
                rawText: result.text,
                processedText: draft.text,
                audioFileName: recording.fileURL.lastPathComponent,
                audioDuration: recording.duration,
                transcriptionDuration: result.transcriptionDuration,
                thermalStateBefore: thermalStateBefore,
                thermalStateAfter: ProcessInfo.processInfo.thermalState.wordhandName
            )
            try MobileConfiguration.benchmarkStore().save(observation)
            state = .readyInKeyboard(draft.text)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func clearFailure() {
        if case .failed = state {
            state = .ready
        }
    }

    private func requestPermissions() async -> Bool {
        let speechAuthorized = await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechAuthorized else { return false }

        return await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

private extension ProcessInfo.ThermalState {
    var wordhandName: String {
        switch self {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }
}
