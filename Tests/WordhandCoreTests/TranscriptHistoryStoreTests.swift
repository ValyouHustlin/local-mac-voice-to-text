import Foundation
import SQLite3
import Testing
@testable import WordhandCore

@Suite
struct TranscriptHistoryStoreTests {
    @Test
    func persistsNewestFirstAndSearchesRawAndProcessedText() throws {
        let fixture = try HistoryFixture()
        let older = fixture.record(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 100),
            rawText: "send this résumé to air on",
            text: "Send this résumé to Aaron."
        )
        let newer = fixture.record(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            createdAt: Date(timeIntervalSince1970: 200),
            rawText: "ship the wordhand window",
            text: "Ship the Wordhand window."
        )

        try fixture.store.save(older)
        try fixture.store.save(newer)

        #expect(try fixture.store.records().map(\.id) == [newer.id, older.id])
        #expect(try fixture.store.records(matching: "WORDHAND").map(\.id) == [newer.id])
        #expect(try fixture.store.records(matching: "air on").map(\.id) == [older.id])
        #expect(try fixture.store.records(matching: "RÉSUMÉ").map(\.id) == [older.id])

        let reopened = try TranscriptHistoryStore(fileURL: fixture.databaseURL)
        #expect(try reopened.records().map(\.id) == [newer.id, older.id])

        let databasePermissions = try #require(
            FileManager.default.attributesOfItem(atPath: fixture.databaseURL.path)[
                .posixPermissions
            ] as? NSNumber
        )
        let directoryPermissions = try #require(
            FileManager.default.attributesOfItem(
                atPath: fixture.databaseURL.deletingLastPathComponent().path
            )[.posixPermissions] as? NSNumber
        )
        #expect(databasePermissions.intValue == 0o600)
        #expect(directoryPermissions.intValue == 0o700)
    }

    @Test
    func updatesInsertionStatusWithoutLosingTranscript() throws {
        let fixture = try HistoryFixture()
        let record = fixture.record(text: "Recover this transcript.")
        try fixture.store.save(record)

        try fixture.store.updateStatus(
            id: record.id,
            status: .insertionFailed("Accessibility permission is missing.")
        )

        let loaded = try #require(try fixture.store.records().first)
        #expect(loaded.text == record.text)
        #expect(loaded.status == .insertionFailed("Accessibility permission is missing."))

        try fixture.store.updateStatus(id: record.id, status: .inserted)
        #expect(try fixture.store.records().first?.status == .inserted)
    }

    @Test
    func storesCorrectedReferenceTextForQualityEvaluation() throws {
        let fixture = try HistoryFixture()
        let record = fixture.record(text: "Value ships whisper kid.")
        try fixture.store.save(record)

        try fixture.store.updateReferenceText(
            id: record.id,
            referenceText: "Valyou ships WhisperKit."
        )

        let loaded = try #require(try fixture.store.records().first)
        #expect(loaded.referenceText == "Valyou ships WhisperKit.")
        #expect(
            try fixture.store.records(matching: "WhisperKit").map(\.id)
                == [record.id]
        )
        #expect(try fixture.store.labeledRecordCount() == 1)
    }

    @Test
    func migratesVersionOneHistoryWithoutLosingRecords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "wordhand-history-v1-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let databaseURL = directory.appendingPathComponent("history.sqlite")
        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        let recordID = UUID()
        let createVersionOne = """
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
            failure_reason TEXT
        );
        INSERT INTO transcripts VALUES (
            '\(recordID.uuidString)', 100, 'raw', 'Existing transcript',
            'whisper-base.en', 'en', 1, 0.2, 'paste',
            'com.apple.TextEdit', 'TextEdit', 'inserted', NULL
        );
        PRAGMA user_version = 1;
        """
        #expect(
            sqlite3_exec(database, createVersionOne, nil, nil, nil) == SQLITE_OK
        )
        sqlite3_close(database)

        let migrated = try TranscriptHistoryStore(fileURL: databaseURL)
        let record = try #require(try migrated.records().first)

        #expect(record.id == recordID)
        #expect(record.text == "Existing transcript")
        #expect(record.referenceText == nil)
        try migrated.updateReferenceText(
            id: recordID,
            referenceText: "Corrected transcript"
        )
        #expect(
            try migrated.records().first?.referenceText == "Corrected transcript"
        )
    }

    @Test
    func deletesPrunesAndClearsRecords() throws {
        let fixture = try HistoryFixture()
        let old = fixture.record(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            createdAt: Date(timeIntervalSince1970: 100),
            text: "Old transcript"
        )
        let recent = fixture.record(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            createdAt: Date(timeIntervalSince1970: 300),
            text: "Recent transcript"
        )
        try fixture.store.save(old)
        try fixture.store.save(recent)

        #expect(try fixture.store.prune(before: Date(timeIntervalSince1970: 200)) == 1)
        #expect(try fixture.store.records().map(\.id) == [recent.id])

        try fixture.store.delete(id: recent.id)
        #expect(try fixture.store.records().isEmpty)

        try fixture.store.save(old)
        try fixture.store.save(recent)
        #expect(try fixture.store.clear() == 2)
        #expect(try fixture.store.records().isEmpty)
    }

    @Test
    func rejectsDuplicateAndMissingRecords() throws {
        let fixture = try HistoryFixture()
        let record = fixture.record(text: "Only once")
        try fixture.store.save(record)

        #expect(throws: TranscriptHistoryError.duplicateRecord(record.id)) {
            try fixture.store.save(record)
        }
        let missing = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        #expect(throws: TranscriptHistoryError.missingRecord(missing)) {
            try fixture.store.updateStatus(id: missing, status: .inserted)
        }
        #expect(throws: TranscriptHistoryError.missingRecord(missing)) {
            try fixture.store.updateReferenceText(
                id: missing,
                referenceText: "Missing"
            )
        }
    }

    @Test
    func rejectsNewerSchemaWithoutOverwritingIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wordhand-history-schema-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let databaseURL = directory.appendingPathComponent("history.sqlite")

        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "PRAGMA user_version = 99", nil, nil, nil) == SQLITE_OK)

        #expect(throws: TranscriptHistoryError.unsupportedSchema(99)) {
            _ = try TranscriptHistoryStore(fileURL: databaseURL)
        }

        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 99)
    }
}

private final class HistoryFixture {
    let directory: URL
    let databaseURL: URL
    let store: TranscriptHistoryStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wordhand-history-tests-\(UUID().uuidString)", isDirectory: true)
        databaseURL = directory.appendingPathComponent("history.sqlite")
        store = try TranscriptHistoryStore(fileURL: databaseURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func record(
        id: UUID = UUID(),
        createdAt: Date = Date(timeIntervalSince1970: 1_000),
        rawText: String = "raw transcript",
        text: String
    ) -> TranscriptRecord {
        TranscriptRecord(
            id: id,
            createdAt: createdAt,
            rawText: rawText,
            text: text,
            modelID: "whisper-base.en",
            language: "en",
            audioDuration: 2.4,
            transcriptionDuration: 0.8,
            insertionMode: .unicode,
            target: TranscriptTarget(
                bundleIdentifier: "com.apple.TextEdit",
                applicationName: "TextEdit"
            ),
            status: .pendingInsertion
        )
    }
}
