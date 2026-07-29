import Foundation

public final class MutableTranscriptProcessor: TranscriptProcessing, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [DictionaryEntry]

    public init(dictionaryEntries: [DictionaryEntry] = []) {
        entries = dictionaryEntries
    }

    public func update(dictionaryEntries: [DictionaryEntry]) {
        lock.withLock {
            entries = dictionaryEntries
        }
    }

    public func process(_ text: String, target: TranscriptTarget = .unknown) async -> String {
        let snapshot = lock.withLock { entries }
        let sanitized = TranscriptProcessor.sanitize(text)
        let substituted = DictionaryMatcher(entries: snapshot).apply(to: sanitized)
        let withoutFillers = TranscriptProcessor.removeSpeechFillers(substituted)
        return SpokenCorrectionEngine.apply(to: withoutFillers)
    }
}
