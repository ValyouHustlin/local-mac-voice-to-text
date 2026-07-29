import Foundation

public final class MutableTranscriptProcessor: TranscriptProcessing, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [DictionaryEntry]

    public init(dictionaryEntries: [DictionaryEntry] = []) {
        entries = dictionaryEntries
    }

    public func update(dictionaryEntries: [DictionaryEntry]) {
        lock.lock()
        entries = dictionaryEntries
        lock.unlock()
    }

    public func process(_ text: String) -> String {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        return TranscriptProcessor(dictionaryEntries: snapshot).process(text)
    }
}
