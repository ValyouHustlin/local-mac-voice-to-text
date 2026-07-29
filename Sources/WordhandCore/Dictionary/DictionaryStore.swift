import Foundation

public struct DictionaryDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var installedDefaultVocabularyVersion: Int
    public var entries: [DictionaryEntry]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        installedDefaultVocabularyVersion: Int = 0,
        entries: [DictionaryEntry] = []
    ) {
        self.schemaVersion = schemaVersion
        self.installedDefaultVocabularyVersion = installedDefaultVocabularyVersion
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case installedDefaultVocabularyVersion
        case entries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        installedDefaultVocabularyVersion =
            try container.decodeIfPresent(Int.self, forKey: .installedDefaultVocabularyVersion) ?? 0
        entries = try container.decode([DictionaryEntry].self, forKey: .entries)
    }

    public func validated() throws -> DictionaryDocument {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DictionaryStoreError.unsupportedSchema(schemaVersion)
        }
        guard installedDefaultVocabularyVersion >= 0 else {
            throw DictionaryStoreError.invalidDefaultVocabularyVersion(
                installedDefaultVocabularyVersion
            )
        }

        var seenIDs = Set<UUID>()
        var seenMatches = Set<String>()
        for entry in entries {
            guard !entry.spokenForm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DictionaryStoreError.emptySpokenForm
            }
            guard !entry.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DictionaryStoreError.emptyReplacement
            }
            guard seenIDs.insert(entry.id).inserted else {
                throw DictionaryStoreError.duplicateID(entry.id)
            }

            let spokenKey = entry.isCaseSensitive
                ? entry.spokenForm
                : entry.spokenForm.folding(
                    options: [.caseInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
            let matchKey = "\(entry.matchMode.rawValue)|\(entry.isCaseSensitive)|\(spokenKey)"
            guard seenMatches.insert(matchKey).inserted else {
                throw DictionaryStoreError.duplicateSpokenForm(entry.spokenForm)
            }
        }
        return self
    }
}

public enum DictionaryStoreError: Error, Equatable {
    case unsupportedSchema(Int)
    case emptySpokenForm
    case emptyReplacement
    case duplicateID(UUID)
    case duplicateSpokenForm(String)
    case missingEntry(UUID)
    case invalidDefaultVocabularyVersion(Int)
    case emptyDefaultVocabulary
    case emptyDefaultVocabularyTerm
    case duplicateDefaultVocabularyTerm(String)
    case missingDefaultVocabulary
}

public struct DictionaryStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        ApplicationData.defaultDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("dictionary.json")
    }

    public func load() throws -> DictionaryDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return DictionaryDocument()
        }
        try hardenPermissions()
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        if let document = try? decoder.decode(DictionaryDocument.self, from: data) {
            return try document.validated()
        }

        // Early development builds stored only the entry array. Accept that
        // shape once and immediately migrate it to the versioned document.
        if let legacyEntries = try? decoder.decode([DictionaryEntry].self, from: data) {
            let migrated = try DictionaryDocument(entries: legacyEntries).validated()
            try save(migrated)
            return migrated
        }

        return try decoder.decode(DictionaryDocument.self, from: data).validated()
    }

    public func save(_ document: DictionaryDocument) throws {
        let validated = try document.validated()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(validated)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fileURL.deletingLastPathComponent().path
        )
        try data.write(to: fileURL, options: [.atomic])
        try hardenPermissions()
    }

    @discardableResult
    public func installDefaults(_ seed: DictionaryVocabularySeed) throws -> DictionaryDocument {
        let seed = try seed.validated()
        var document = try load()
        let seedOrder = Dictionary(
            uniqueKeysWithValues: seed.terms.enumerated().map { offset, term in
                (
                    term.folding(
                        options: [.caseInsensitive],
                        locale: Locale(identifier: "en_US_POSIX")
                    ),
                    offset
                )
            }
        )
        var metadataChanged = false
        for index in document.entries.indices
        where document.entries[index].origin == .starterVocabulary
            && document.entries[index].starterVocabularyOrder == nil
        {
            let key = document.entries[index].replacement.folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            if let order = seedOrder[key] {
                document.entries[index].starterVocabularyOrder = order
                metadataChanged = true
            }
        }
        guard document.installedDefaultVocabularyVersion < seed.version else {
            if metadataChanged {
                try save(document)
            }
            return document
        }

        var canonicalTerms = Set(document.entries.map {
            $0.replacement
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(
                    options: [.caseInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
        })
        let installedAt = Date()
        for (starterOrder, term) in seed.terms.enumerated() {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard canonicalTerms.insert(key).inserted else { continue }
            document.entries.append(DictionaryEntry(
                spokenForm: trimmed,
                replacement: trimmed,
                origin: .starterVocabulary,
                starterVocabularyOrder: starterOrder,
                createdAt: installedAt,
                updatedAt: installedAt
            ))
        }
        document.installedDefaultVocabularyVersion = seed.version
        try save(document)
        return document
    }

    @discardableResult
    public func installBundledDefaults() throws -> DictionaryDocument {
        try installDefaults(BundledDictionaryVocabulary.load())
    }

    @discardableResult
    public func upsert(_ entry: DictionaryEntry) throws -> DictionaryDocument {
        var document = try load()
        if let index = document.entries.firstIndex(where: { $0.id == entry.id }) {
            document.entries[index] = entry
        } else {
            document.entries.append(entry)
        }
        try save(document)
        return document
    }

    @discardableResult
    public func delete(id: UUID) throws -> DictionaryDocument {
        var document = try load()
        guard let index = document.entries.firstIndex(where: { $0.id == id }) else {
            throw DictionaryStoreError.missingEntry(id)
        }
        document.entries.remove(at: index)
        try save(document)
        return document
    }

    private func hardenPermissions() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
