import Foundation
import Testing
@testable import WordhandCore

@Suite("Application data migration")
struct ApplicationDataTests {
    @Test("Copies legacy data once without deleting the rollback source")
    func copiesLegacyData() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let legacy = ApplicationData.legacyDirectory(homeDirectory: home)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let legacyFile = legacy.appendingPathComponent("dictionary.json")
        try Data("legacy".utf8).write(to: legacyFile)

        #expect(try ApplicationData.migrateLegacyDataIfNeeded(homeDirectory: home))

        let currentFile = ApplicationData.defaultDirectory(homeDirectory: home)
            .appendingPathComponent("dictionary.json")
        #expect(try String(contentsOf: currentFile, encoding: .utf8) == "legacy")
        #expect(FileManager.default.fileExists(atPath: legacyFile.path))
        #expect(try !ApplicationData.migrateLegacyDataIfNeeded(homeDirectory: home))
    }

    @Test("Never overwrites an existing Wordhand directory")
    func preservesExistingDestination() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let legacy = ApplicationData.legacyDirectory(homeDirectory: home)
        let current = ApplicationData.defaultDirectory(homeDirectory: home)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacy.appendingPathComponent("settings.json"))
        let currentFile = current.appendingPathComponent("settings.json")
        try Data("current".utf8).write(to: currentFile)

        #expect(try !ApplicationData.migrateLegacyDataIfNeeded(homeDirectory: home))
        #expect(try String(contentsOf: currentFile, encoding: .utf8) == "current")
    }

    @Test("Does nothing when no legacy directory exists")
    func noLegacyDirectory() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(try !ApplicationData.migrateLegacyDataIfNeeded(homeDirectory: home))
        #expect(!FileManager.default.fileExists(
            atPath: ApplicationData.defaultDirectory(homeDirectory: home).path
        ))
    }

    private func temporaryHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wordhand-data-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
