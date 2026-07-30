import Foundation
import Testing
@testable import WordhandCore

@Suite
struct SettingsTests {
    @Test
    func safeModeBlocksGlobalInputBeforeRuntimeSetup() {
        #expect(
            GlobalInputSafetyPolicy.blocksGlobalInput(
                environment: ["WORDHAND_SAFE": "1"]
            )
        )
        #expect(
            GlobalInputSafetyPolicy.blocksGlobalInput(
                environment: ["WORDHAND_SAFE": " true "]
            )
        )
        #expect(
            !GlobalInputSafetyPolicy.blocksGlobalInput(
                environment: ["WORDHAND_SAFE": "0"]
            )
        )
        #expect(!GlobalInputSafetyPolicy.blocksGlobalInput(environment: [:]))
    }

    @Test
    func developmentGlobalInputTestRequiresOptInAndBoundedTimeout() {
        #expect(
            GlobalInputSafetyPolicy.hasInvalidDevelopmentTestConfiguration(
                optedIn: false,
                timeoutSeconds: 10
            )
        )
        #expect(
            GlobalInputSafetyPolicy.hasInvalidDevelopmentTestConfiguration(
                optedIn: true,
                timeoutSeconds: nil
            )
        )
        #expect(
            GlobalInputSafetyPolicy.hasInvalidDevelopmentTestConfiguration(
                optedIn: true,
                timeoutSeconds: 31
            )
        )
        #expect(
            !GlobalInputSafetyPolicy.hasInvalidDevelopmentTestConfiguration(
                optedIn: true,
                timeoutSeconds: 10
            )
        )
    }

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
    func dailyRuntimeKeepsFullBufferTranscriptionAuthoritative() {
        #expect(!ProcessingPerformanceMode.adaptive.enablesRollingTranscription)
        #expect(!ProcessingPerformanceMode.maximum.enablesRollingTranscription)
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
        expected.soundEffectsEnabled = false
        expected.formattingProfile = .aiCommunication
        expected.performanceMode = .maximum
        expected.insertionMode = .unicode

        try store.save(expected)

        #expect(try store.load() == expected)
        let filePermissions = try #require(
            FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions]
                as? NSNumber
        )
        let directoryPermissions = try #require(
            FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions]
                as? NSNumber
        )
        #expect(filePermissions.intValue == 0o600)
        #expect(directoryPermissions.intValue == 0o700)
    }

    @Test
    func missingStoreReturnsDefaults() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("settings.json")
        #expect(try SettingsStore(fileURL: url).load() == AppSettings())
    }

    @Test
    func loadsThePreRecorderHotkeyShape() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "modelID": "whisper-base.en",
              "insertionMode": "unicode",
              "showOverlay": true,
              "historyRetentionDays": 30,
              "hotkeys": [{
                "key": "space",
                "modifiers": ["control"],
                "action": "pushToTalk"
              }]
            }
            """.utf8
        )

        let settings = try JSONDecoder().decode(AppSettings.self, from: data).validated()

        #expect(settings.hotkeys.first?.keyCode == 49)
        #expect(settings.hotkeys.first?.displayName == "⌃Space")
        #expect(settings.soundEffectsEnabled)
        #expect(settings.formattingProfile == .formatted)
        #expect(settings.performanceMode == .adaptive)
    }

    @Test
    func rejectsBareAndDuplicateShortcuts() {
        #expect(throws: SettingsError.invalidHotkey) {
            _ = try AppSettings(hotkeys: [
                HotkeyBinding(
                    key: "d",
                    keyCode: 2,
                    modifiers: [],
                    action: .pushToTalk
                ),
            ]).validated()
        }

        #expect(throws: SettingsError.duplicateHotkey) {
            _ = try AppSettings(hotkeys: [
                HotkeyBinding(
                    key: "space",
                    keyCode: 49,
                    modifiers: ["control"],
                    action: .pushToTalk
                ),
                HotkeyBinding(
                    key: "space",
                    keyCode: 49,
                    modifiers: ["control"],
                    action: .toggleRecording
                ),
            ]).validated()
        }
    }
}
