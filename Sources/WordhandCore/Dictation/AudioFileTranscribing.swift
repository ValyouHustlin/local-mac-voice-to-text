import Foundation

public struct AudioFileTranscription: Equatable, Sendable {
    public let text: String
    public let engineID: String
    public let localeIdentifier: String
    public let transcriptionDuration: TimeInterval

    public init(
        text: String,
        engineID: String,
        localeIdentifier: String,
        transcriptionDuration: TimeInterval
    ) {
        self.text = text
        self.engineID = engineID
        self.localeIdentifier = localeIdentifier
        self.transcriptionDuration = transcriptionDuration
    }
}

/// Cross-platform engine boundary for a locally stored audio corpus.
///
/// Implementations may use Apple Speech, WhisperKit, or another on-device
/// engine, but must not upload the audio file or transcript.
public protocol AudioFileTranscribing: Sendable {
    var engineID: String { get }

    func transcribe(
        audioFileURL: URL,
        localeIdentifier: String
    ) async throws -> AudioFileTranscription
}
