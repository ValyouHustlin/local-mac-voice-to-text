import Foundation
import SQLite3

public enum TranscriptHistoryError: Error, Equatable {
    case unsupportedSchema(Int)
    case duplicateRecord(UUID)
    case missingRecord(UUID)
    case database(String)
}

public final class TranscriptHistoryStore: TranscriptRecording, @unchecked Sendable {
    public static let currentSchemaVersion = 3

    public let fileURL: URL

    private var database: OpaquePointer?
    private let lock = NSLock()

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fileURL.deletingLastPathComponent().path
        )

        var opened: OpaquePointer?
        let result = sqlite3_open_v2(
            fileURL.path,
            &opened,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let opened else {
            let message = Self.errorMessage(from: opened, fallbackCode: result)
            if let opened { sqlite3_close(opened) }
            throw TranscriptHistoryError.database(message)
        }
        database = opened

        do {
            try configureAndMigrate()
            try hardenDatabasePermissions()
        } catch {
            sqlite3_close(opened)
            database = nil
            throw error
        }
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        ApplicationData.defaultDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("history.sqlite")
    }

    public func save(_ record: TranscriptRecord) throws {
        try locked {
            let statement = try prepare(
                """
                INSERT INTO transcripts (
                    id, created_at, raw_text, processed_text, model_id, language,
                    audio_duration, transcription_duration, insertion_mode,
                    target_bundle_id, target_app_name, insertion_status,
                    failure_reason, reference_text, tail_recovery_outcome
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            )
            defer { sqlite3_finalize(statement) }

            bind(record.id.uuidString, to: 1, in: statement)
            sqlite3_bind_double(statement, 2, record.createdAt.timeIntervalSince1970)
            bind(record.rawText, to: 3, in: statement)
            bind(record.text, to: 4, in: statement)
            bind(record.modelID, to: 5, in: statement)
            bind(record.language, to: 6, in: statement)
            sqlite3_bind_double(statement, 7, record.audioDuration)
            sqlite3_bind_double(statement, 8, record.transcriptionDuration)
            bind(record.insertionMode.rawValue, to: 9, in: statement)
            bind(record.target.bundleIdentifier, to: 10, in: statement)
            bind(record.target.applicationName, to: 11, in: statement)
            let encodedStatus = Self.encode(record.status)
            bind(encodedStatus.value, to: 12, in: statement)
            bind(encodedStatus.reason, to: 13, in: statement)
            bind(record.referenceText, to: 14, in: statement)
            bind(record.tailRecoveryOutcome.rawValue, to: 15, in: statement)

            let result = sqlite3_step(statement)
            if result == SQLITE_CONSTRAINT {
                throw TranscriptHistoryError.duplicateRecord(record.id)
            }
            guard result == SQLITE_DONE else {
                throw databaseError(result)
            }
        }
    }

    public func updateStatus(id: UUID, status: TranscriptInsertionStatus) throws {
        try locked {
            let statement = try prepare(
                """
                UPDATE transcripts
                SET insertion_status = ?, failure_reason = ?
                WHERE id = ?
                """
            )
            defer { sqlite3_finalize(statement) }
            let encoded = Self.encode(status)
            bind(encoded.value, to: 1, in: statement)
            bind(encoded.reason, to: 2, in: statement)
            bind(id.uuidString, to: 3, in: statement)
            try stepToCompletion(statement)
            guard sqlite3_changes(database) == 1 else {
                throw TranscriptHistoryError.missingRecord(id)
            }
        }
    }

    public func updateReferenceText(id: UUID, referenceText: String?) throws {
        try locked {
            let statement = try prepare(
                "UPDATE transcripts SET reference_text = ? WHERE id = ?"
            )
            defer { sqlite3_finalize(statement) }
            let normalized = referenceText?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            bind(normalized?.isEmpty == false ? normalized : nil, to: 1, in: statement)
            bind(id.uuidString, to: 2, in: statement)
            try stepToCompletion(statement)
            guard sqlite3_changes(database) == 1 else {
                throw TranscriptHistoryError.missingRecord(id)
            }
        }
    }

    public func labeledRecordCount() throws -> Int {
        try locked {
            let statement = try prepare(
                """
                SELECT COUNT(*) FROM transcripts
                WHERE reference_text IS NOT NULL AND trim(reference_text) <> ''
                """
            )
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw databaseError(sqlite3_errcode(database))
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    public func records(matching query: String = "", limit: Int = 500) throws
        -> [TranscriptRecord]
    {
        try locked {
            let statement = try prepare(
                """
                SELECT
                    id, created_at, raw_text, processed_text, model_id, language,
                    audio_duration, transcription_duration, insertion_mode,
                    target_bundle_id, target_app_name, insertion_status,
                    failure_reason, reference_text, tail_recovery_outcome
                FROM transcripts
                ORDER BY created_at DESC, rowid DESC
                LIMIT ?
                """
            )
            defer { sqlite3_finalize(statement) }

            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedLimit = max(1, min(limit, 5_000))
            let fetchLimit = trimmedQuery.isEmpty ? requestedLimit : 5_000
            sqlite3_bind_int(statement, 1, Int32(fetchLimit))

            var records: [TranscriptRecord] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else {
                    throw databaseError(result)
                }
                let record = try decodeRecord(from: statement)
                if trimmedQuery.isEmpty || Self.matches(record, query: trimmedQuery) {
                    records.append(record)
                    if records.count == requestedLimit { break }
                }
            }
            return records
        }
    }

    public func delete(id: UUID) throws {
        try locked {
            let statement = try prepare("DELETE FROM transcripts WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            bind(id.uuidString, to: 1, in: statement)
            try stepToCompletion(statement)
            guard sqlite3_changes(database) == 1 else {
                throw TranscriptHistoryError.missingRecord(id)
            }
        }
    }

    @discardableResult
    public func clear() throws -> Int {
        try locked {
            try execute("DELETE FROM transcripts")
            return Int(sqlite3_changes(database))
        }
    }

    @discardableResult
    public func prune(before cutoff: Date) throws -> Int {
        try locked {
            let statement = try prepare("DELETE FROM transcripts WHERE created_at < ?")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
            try stepToCompletion(statement)
            return Int(sqlite3_changes(database))
        }
    }

    private func configureAndMigrate() throws {
        try locked {
            guard let database else {
                throw TranscriptHistoryError.database("History database is closed.")
            }
            sqlite3_busy_timeout(database, 2_000)
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")

            let versionStatement = try prepare("PRAGMA user_version")
            defer { sqlite3_finalize(versionStatement) }
            guard sqlite3_step(versionStatement) == SQLITE_ROW else {
                throw databaseError(sqlite3_errcode(database))
            }
            var version = Int(sqlite3_column_int(versionStatement, 0))
            guard version <= Self.currentSchemaVersion else {
                throw TranscriptHistoryError.unsupportedSchema(version)
            }
            if version == 0 {
                try execute("BEGIN IMMEDIATE")
                do {
                    try execute(
                        """
                        CREATE TABLE transcripts (
                            id TEXT PRIMARY KEY NOT NULL,
                            created_at REAL NOT NULL,
                            raw_text TEXT NOT NULL,
                            processed_text TEXT NOT NULL,
                            model_id TEXT NOT NULL,
                            language TEXT,
                            audio_duration REAL NOT NULL,
                            transcription_duration REAL NOT NULL,
                            insertion_mode TEXT NOT NULL,
                            target_bundle_id TEXT,
                            target_app_name TEXT,
                            insertion_status TEXT NOT NULL,
                            failure_reason TEXT,
                            reference_text TEXT,
                            tail_recovery_outcome TEXT NOT NULL
                                DEFAULT 'not_audited'
                        )
                        """
                    )
                    try execute(
                        "CREATE INDEX transcripts_created_at "
                            + "ON transcripts(created_at DESC)"
                    )
                    try execute("PRAGMA user_version = \(Self.currentSchemaVersion)")
                    try execute("COMMIT")
                } catch {
                    try? execute("ROLLBACK")
                    throw error
                }
                return
            }

            if version == 1 {
                try execute("BEGIN IMMEDIATE")
                do {
                    try execute(
                        "ALTER TABLE transcripts ADD COLUMN reference_text TEXT"
                    )
                    try execute("PRAGMA user_version = 2")
                    try execute("COMMIT")
                    version = 2
                } catch {
                    try? execute("ROLLBACK")
                    throw error
                }
            }

            if version == 2 {
                try execute("BEGIN IMMEDIATE")
                do {
                    try execute(
                        """
                        ALTER TABLE transcripts
                        ADD COLUMN tail_recovery_outcome TEXT NOT NULL
                        DEFAULT 'not_audited'
                        """
                    )
                    try execute("PRAGMA user_version = 3")
                    try execute("COMMIT")
                } catch {
                    try? execute("ROLLBACK")
                    throw error
                }
            }
        }
    }

    private func hardenDatabasePermissions() throws {
        for suffix in ["", "-wal", "-shm"] {
            let path = fileURL.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path
            )
        }
    }

    private func decodeRecord(from statement: OpaquePointer) throws -> TranscriptRecord {
        guard
            let idString = string(at: 0, in: statement),
            let id = UUID(uuidString: idString),
            let rawText = string(at: 2, in: statement),
            let processedText = string(at: 3, in: statement),
            let modelID = string(at: 4, in: statement),
            let insertionModeValue = string(at: 8, in: statement),
            let insertionMode = InsertionMode(rawValue: insertionModeValue),
            let statusValue = string(at: 11, in: statement),
            let tailRecoveryValue = string(at: 14, in: statement),
            let tailRecoveryOutcome = TailRecoveryOutcome(
                rawValue: tailRecoveryValue
            )
        else {
            throw TranscriptHistoryError.database("History contains an invalid record.")
        }

        let status = try Self.decodeStatus(
            statusValue,
            reason: string(at: 12, in: statement)
        )
        return TranscriptRecord(
            id: id,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            rawText: rawText,
            text: processedText,
            modelID: modelID,
            language: string(at: 5, in: statement),
            audioDuration: sqlite3_column_double(statement, 6),
            transcriptionDuration: sqlite3_column_double(statement, 7),
            insertionMode: insertionMode,
            target: TranscriptTarget(
                bundleIdentifier: string(at: 9, in: statement),
                applicationName: string(at: 10, in: statement)
            ),
            status: status,
            referenceText: string(at: 13, in: statement),
            tailRecoveryOutcome: tailRecoveryOutcome
        )
    }

    private static func encode(_ status: TranscriptInsertionStatus)
        -> (value: String, reason: String?)
    {
        switch status {
        case .pendingInsertion:
            return ("pending", nil)
        case .inserted:
            return ("inserted", nil)
        case .insertionFailed(let reason):
            return ("insertion_failed", reason)
        }
    }

    private static func decodeStatus(_ value: String, reason: String?) throws
        -> TranscriptInsertionStatus
    {
        switch value {
        case "pending":
            return .pendingInsertion
        case "inserted":
            return .inserted
        case "insertion_failed":
            return .insertionFailed(reason ?? "Insertion failed.")
        default:
            throw TranscriptHistoryError.database("Unknown history status: \(value)")
        }
    }

    private static func matches(_ record: TranscriptRecord, query: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let candidates = [
            record.text,
            record.rawText,
            record.referenceText ?? "",
            record.target.applicationName ?? "",
        ]
        return candidates.contains {
            $0.range(of: query, options: options, locale: .current) != nil
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func execute(_ sql: String) throws {
        guard let database else {
            throw TranscriptHistoryError.database("History database is closed.")
        }
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) }
                ?? Self.errorMessage(from: database, fallbackCode: result)
            sqlite3_free(error)
            throw TranscriptHistoryError.database(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else {
            throw TranscriptHistoryError.database("History database is closed.")
        }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw databaseError(result)
        }
        return statement
    }

    private func stepToCompletion(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw databaseError(result)
        }
    }

    private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func string(at index: Int32, in statement: OpaquePointer) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index)
        else {
            return nil
        }
        return String(cString: value)
    }

    private func databaseError(_ code: Int32) -> TranscriptHistoryError {
        .database(Self.errorMessage(from: database, fallbackCode: code))
    }

    private static func errorMessage(from database: OpaquePointer?, fallbackCode: Int32) -> String {
        if let database, let message = sqlite3_errmsg(database) {
            return String(cString: message)
        }
        return "SQLite error \(fallbackCode)"
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
