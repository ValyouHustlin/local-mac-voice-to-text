import Foundation

public final class MutableTranscriptProcessor: TranscriptProcessing, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [DictionaryEntry]
    private var formattingProfile: TranscriptFormattingProfile

    public init(
        dictionaryEntries: [DictionaryEntry] = [],
        formattingProfile: TranscriptFormattingProfile = .verbatim
    ) {
        entries = dictionaryEntries
        self.formattingProfile = formattingProfile
    }

    public func update(dictionaryEntries: [DictionaryEntry]) {
        lock.withLock {
            entries = dictionaryEntries
        }
    }

    public func update(formattingProfile: TranscriptFormattingProfile) {
        lock.withLock {
            self.formattingProfile = formattingProfile
        }
    }

    public func process(_ text: String, target: TranscriptTarget = .unknown) async -> String {
        let snapshot = lock.withLock { (entries, formattingProfile) }
        return await TranscriptProcessor(
            dictionaryEntries: snapshot.0,
            formattingProfile: snapshot.1
        ).process(text, target: target)
    }
}
