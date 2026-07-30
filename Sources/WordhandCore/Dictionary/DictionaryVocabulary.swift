import Foundation

public struct DictionaryVocabularySeed: Codable, Equatable, Sendable {
    public let version: Int
    public let terms: [String]

    public init(version: Int, terms: [String]) {
        self.version = version
        self.terms = terms
    }

    public func validated() throws -> DictionaryVocabularySeed {
        guard version > 0 else {
            throw DictionaryStoreError.invalidDefaultVocabularyVersion(version)
        }
        guard !terms.isEmpty else {
            throw DictionaryStoreError.emptyDefaultVocabulary
        }

        var seen = Set<String>()
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw DictionaryStoreError.emptyDefaultVocabularyTerm
            }
            let key = trimmed.folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard seen.insert(key).inserted else {
                throw DictionaryStoreError.duplicateDefaultVocabularyTerm(term)
            }
        }
        return self
    }
}

public enum BundledDictionaryVocabulary {
    public static func load() throws -> DictionaryVocabularySeed {
        let appResourceURL = Bundle.main.url(
            forResource: "default-vocabulary",
            withExtension: "json"
        )
        let packageResourceURL = Bundle.module.url(
            forResource: "default-vocabulary",
            withExtension: "json"
        )
        guard let url = appResourceURL ?? packageResourceURL else {
            throw DictionaryStoreError.missingDefaultVocabulary
        }
        return try JSONDecoder()
            .decode(DictionaryVocabularySeed.self, from: Data(contentsOf: url))
            .validated()
    }
}

public final class DictionaryVocabularySource: @unchecked Sendable {
    public static let maximumPromptTerms = 24

    private let lock = NSLock()
    private var entries: [DictionaryEntry]

    public init(entries: [DictionaryEntry] = []) {
        self.entries = entries
    }

    public func update(entries: [DictionaryEntry]) {
        lock.withLock {
            self.entries = entries
        }
    }

    public func terms() -> [String] {
        let snapshot = lock.withLock { entries }
        var seen = Set<String>()
        let prioritized = snapshot.enumerated().sorted { left, right in
            let leftIsCustom = left.element.origin != .starterVocabulary
            let rightIsCustom = right.element.origin != .starterVocabulary
            if leftIsCustom != rightIsCustom {
                return leftIsCustom
            }
            if leftIsCustom, left.element.updatedAt != right.element.updatedAt {
                return left.element.updatedAt > right.element.updatedAt
            }
            if !leftIsCustom {
                let leftOrder = left.element.starterVocabularyOrder ?? Int.max
                let rightOrder = right.element.starterVocabularyOrder ?? Int.max
                if leftOrder != rightOrder {
                    return leftOrder < rightOrder
                }
            }
            return left.offset < right.offset
        }
        return prioritized.compactMap { indexedEntry in
            let entry = indexedEntry.element
            guard entry.isEnabled else { return nil }
            let canonical = entry.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty else { return nil }
            let key = canonical.folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard seen.insert(key).inserted else { return nil }
            return canonical
        }.prefix(Self.maximumPromptTerms).map(\.self)
    }

    public func prompt() -> String? {
        let canonicalTerms = terms()
        guard !canonicalTerms.isEmpty else { return nil }
        // Whisper treats this as prior transcript context, not as an
        // instruction. Put the highest-priority and most recently corrected
        // terms nearest the decode boundary, where conditioning is strongest.
        let orderedTerms = canonicalTerms.reversed().joined(separator: ", ")
        let strongestTerms = canonicalTerms.prefix(4).reversed().joined(separator: ", ")
        return """
        Vocabulary: \(orderedTerms). Preferred spellings: \(strongestTerms).
        """
    }
}
