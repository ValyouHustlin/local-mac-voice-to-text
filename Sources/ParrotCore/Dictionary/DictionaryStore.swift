import Foundation

public struct DictionaryDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var entries: [DictionaryEntry]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        entries: [DictionaryEntry] = []
    ) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }

    public func validated() throws -> DictionaryDocument {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DictionaryStoreError.unsupportedSchema(schemaVersion)
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
}

public struct DictionaryStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/Parrot", isDirectory: true)
            .appendingPathComponent("dictionary.json")
    }

    public func load() throws -> DictionaryDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return DictionaryDocument()
        }
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
        try data.write(to: fileURL, options: [.atomic])
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
}
