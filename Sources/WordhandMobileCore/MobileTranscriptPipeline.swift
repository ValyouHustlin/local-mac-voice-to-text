import Foundation
import WordhandCore

public struct MobileTranscriptPipeline: Sendable {
    private let processor: any TranscriptProcessing
    private let store: SharedTranscriptStore
    private let date: @Sendable () -> Date

    public init(
        processor: any TranscriptProcessing = TranscriptProcessor(),
        store: SharedTranscriptStore,
        date: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.processor = processor
        self.store = store
        self.date = date
    }

    @discardableResult
    public func processAndSave(_ rawText: String) throws -> MobileTranscriptDraft {
        let processed = processor.process(rawText)
        let draft = MobileTranscriptDraft(createdAt: date(), text: processed)
        try store.save(draft)
        return draft
    }
}
