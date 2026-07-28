import Foundation
import Testing
@testable import ParrotCore

@Suite
struct SettingsTests {
    @Test
    func defaultsValidate() throws {
        let settings = try AppSettings().validated()
        #expect(
            settings.hotkeys == [
                HotkeyBinding(key: "space", modifiers: ["control"], action: .pushToTalk),
            ]
        )
    }

    @Test
    func rejectsUnknownModelAndInvalidRetention() {
        do {
            _ = try AppSettings(modelID: "missing").validated()
            Issue.record("expected unknown model to fail validation")
        } catch {}

        do {
            _ = try AppSettings(historyRetentionDays: 0).validated()
            Issue.record("expected zero retention to fail validation")
        } catch {}
    }

    @Test
    func storeRoundTripsAndCreatesDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(fileURL: root.appendingPathComponent("settings.json"))
        var expected = AppSettings()
        expected.showOverlay = false
        expected.insertionMode = .unicode

        try store.save(expected)

        #expect(try store.load() == expected)
    }

    @Test
    func missingStoreReturnsDefaults() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("settings.json")
        #expect(try SettingsStore(fileURL: url).load() == AppSettings())
    }
}
