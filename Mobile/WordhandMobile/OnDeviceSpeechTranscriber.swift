import Foundation
import Speech
import WordhandCore

enum OnDeviceSpeechError: LocalizedError {
    case localeUnavailable(String)
    case onDeviceRecognitionUnavailable
    case noFinalResult

    var errorDescription: String? {
        switch self {
        case .localeUnavailable(let identifier):
            return "Apple's speech recognizer is unavailable for \(identifier)."
        case .onDeviceRecognitionUnavailable:
            return "This iPhone has not made its on-device speech model available yet."
        case .noFinalResult:
            return "The local speech model returned no transcript."
        }
    }
}

final class OnDeviceSpeechTranscriber: AudioFileTranscribing, @unchecked Sendable {
    let engineID = "apple-speech-on-device"
    private var recognitionTask: SFSpeechRecognitionTask?

    func transcribe(
        audioFileURL: URL,
        localeIdentifier: String
    ) async throws -> AudioFileTranscription {
        guard let recognizer = SFSpeechRecognizer(
            locale: Locale(identifier: localeIdentifier)
        ) else {
            throw OnDeviceSpeechError.localeUnavailable(localeIdentifier)
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw OnDeviceSpeechError.onDeviceRecognitionUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: audioFileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let startedAt = ProcessInfo.processInfo.systemUptime

        defer { recognitionTask = nil }
        let text = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<String, Error>) in
            var resumed = false
            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let error {
                    resumed = true
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                resumed = true
                let transcription = result.bestTranscription.formattedString
                guard !transcription.isEmpty else {
                    continuation.resume(throwing: OnDeviceSpeechError.noFinalResult)
                    return
                }
                continuation.resume(returning: transcription)
            }
        }

        return AudioFileTranscription(
            text: text,
            engineID: engineID,
            localeIdentifier: localeIdentifier,
            transcriptionDuration: ProcessInfo.processInfo.systemUptime - startedAt
        )
    }
}
