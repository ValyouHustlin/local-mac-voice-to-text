import AVFoundation
import Foundation

struct LocalRecording: Sendable {
    let id: UUID
    let fileURL: URL
    let duration: TimeInterval
}

enum LocalAudioRecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case failedToStart

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A recording is already in progress."
        case .notRecording:
            return "There is no active recording to stop."
        case .failedToStart:
            return "The iPhone microphone could not start recording."
        }
    }
}

@MainActor
final class LocalAudioRecorder {
    private var recorder: AVAudioRecorder?
    private var recordingID: UUID?

    var isRecording: Bool {
        recorder?.isRecording == true
    }

    func start(fileURL: URL, id: UUID) throws {
        guard recorder == nil else {
            throw LocalAudioRecorderError.alreadyRecording
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else {
            try? session.setActive(false)
            throw LocalAudioRecorderError.failedToStart
        }
        self.recorder = recorder
        recordingID = id
    }

    func stop() throws -> LocalRecording {
        guard let recorder, let recordingID else {
            throw LocalAudioRecorderError.notRecording
        }
        let duration = recorder.currentTime
        let fileURL = recorder.url
        recorder.stop()
        self.recorder = nil
        self.recordingID = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
        return LocalRecording(id: recordingID, fileURL: fileURL, duration: duration)
    }

    func cancel() {
        recorder?.stop()
        if let url = recorder?.url {
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        recordingID = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }
}
