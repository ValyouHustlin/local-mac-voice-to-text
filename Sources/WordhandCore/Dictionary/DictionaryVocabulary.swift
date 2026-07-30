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
    public static let maximumPronunciationAliases = 8

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
        Self.canonicalTerms(from: prioritizedEntries())
    }

    public func prompt() -> String? {
        let prioritized = prioritizedEntries()
        let canonicalTerms = Self.canonicalTerms(from: prioritized)
        guard !canonicalTerms.isEmpty else { return nil }
        let canonicalKeys = Set(canonicalTerms.map(Self.normalized))
        var seenAliases = Set<String>()
        let aliases = prioritized.compactMap { entry -> (String, String)? in
            guard entry.isEnabled else { return nil }
            let spoken = entry.spokenForm.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonical = entry.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            let spokenKey = Self.normalized(spoken)
            let canonicalKey = Self.normalized(canonical)
            guard
                !spoken.isEmpty,
                !canonical.isEmpty,
                spokenKey != canonicalKey,
                canonicalKeys.contains(canonicalKey),
                seenAliases.insert(spokenKey).inserted
            else {
                return nil
            }
            return (spoken, canonical)
        }.prefix(Self.maximumPronunciationAliases)

        // Whisper treats this as prior transcript context, not as an
        // instruction. Put the highest-priority and most recently corrected
        // canonical terms nearest the decode boundary, where conditioning is
        // strongest. Associations expose editable pronunciation variants
        // without replacing the canonical terms.
        let orderedTerms = canonicalTerms.reversed().joined(separator: ", ")
        let strongestTerms = canonicalTerms.prefix(4).reversed().joined(separator: ", ")
        let pronunciationGuide = aliases.isEmpty
            ? ""
            : " Pronunciation guide: " + aliases
                .map { "\($0.0) is written \($0.1)" }
                .joined(separator: "; ") + "."
        return """
        Vocabulary: \(orderedTerms).\(pronunciationGuide) Preferred spellings: \(strongestTerms).
        """
    }

    private func prioritizedEntries() -> [DictionaryEntry] {
        let snapshot = lock.withLock { entries }
        return snapshot.enumerated().sorted { left, right in
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
        }.map(\.element)
    }

    private static func canonicalTerms(from prioritized: [DictionaryEntry]) -> [String] {
        var seen = Set<String>()
        return prioritized.compactMap { entry in
            guard entry.isEnabled else { return nil }
            let canonical = entry.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty else { return nil }
            let key = normalized(canonical)
            guard seen.insert(key).inserted else { return nil }
            return canonical
        }.prefix(Self.maximumPromptTerms).map(\.self)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
