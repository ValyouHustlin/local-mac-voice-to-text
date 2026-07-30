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
        #expect(settings.applicationFormattingRules.isEmpty)
    }

    @Test
    func applicationFormattingUsesExactBundleIDAndGlobalFallback() {
        let rules = [
            ApplicationFormattingRule(
                bundleIdentifier: "com.apple.Terminal",
                applicationName: "Terminal",
                profile: .aiCommunication
            ),
        ]

        #expect(ApplicationFormattingProfileRouter.profile(
            default: .formatted,
            rules: rules,
            target: TranscriptTarget(
                bundleIdentifier: "COM.APPLE.TERMINAL",
                applicationName: "Renamed Terminal"
            )
        ) == .aiCommunication)
        #expect(ApplicationFormattingProfileRouter.profile(
            default: .formatted,
            rules: rules,
            target: TranscriptTarget(
                bundleIdentifier: "com.mitchellh.ghostty",
                applicationName: "Terminal"
            )
        ) == .formatted)
        #expect(ApplicationFormattingProfileRouter.profile(
            default: .professional,
            rules: rules,
            target: .unknown
        ) == .professional)
        #expect(ApplicationFormattingProfileRouter.resolve(
            default: .formatted,
            rules: rules + [
                ApplicationFormattingRule(
                    bundleIdentifier: " COM.APPLE.TERMINAL ",
                    applicationName: "Duplicate",
                    profile: .casual
                ),
            ],
            target: TranscriptTarget(
                bundleIdentifier: "com.apple.Terminal",
                applicationName: "Terminal"
            )
        ) == ResolvedApplicationFormattingProfile(
            profile: .formatted,
            source: .ambiguousRuleFallback
        ))
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

        #expect(throws: SettingsError.invalidQualityAudioRetentionDays(0)) {
            _ = try AppSettings(qualityAudioRetentionDays: 0).validated()
        }
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
        expected.applicationFormattingRules = [
            ApplicationFormattingRule(
                bundleIdentifier: "com.apple.Terminal",
                applicationName: "Terminal",
                profile: .aiCommunication
            ),
        ]
        expected.performanceMode = .maximum
        expected.insertionMode = .unicode
        expected.qualityAudioRetentionEnabled = true
        expected.qualityAudioRetentionDays = 14
        expected.qualityAudioMaximumBytes = 5_000_000_000

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
    func storeDropsOnlyAmbiguousApplicationRulesAndPreservesOtherSettings() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let store = SettingsStore(
            fileURL: root.appendingPathComponent("settings.json")
        )
        var persisted = AppSettings(
            insertionMode: .unicode,
            showOverlay: false,
            formattingProfile: .professional,
            applicationFormattingRules: [
                ApplicationFormattingRule(
                    bundleIdentifier: "com.apple.Terminal",
                    applicationName: "Terminal",
                    profile: .aiCommunication
                ),
                ApplicationFormattingRule(
                    bundleIdentifier: "COM.APPLE.TERMINAL",
                    applicationName: "Duplicate Terminal",
                    profile: .casual
                ),
            ],
            performanceMode: .maximum,
            historyRetentionDays: 90
        )
        persisted.hotkeys = [
            HotkeyBinding(
                key: "d",
                keyCode: 2,
                modifiers: ["command", "shift"],
                action: .toggleRecording
            ),
        ]
        let persistedData = try JSONEncoder().encode(persisted)
        try persistedData.write(to: store.fileURL, options: [.atomic])

        let loaded = try store.load()

        #expect(loaded.applicationFormattingRules.isEmpty)
        #expect(loaded.formattingProfile == .professional)
        #expect(loaded.performanceMode == .maximum)
        #expect(loaded.insertionMode == .unicode)
        #expect(!loaded.showOverlay)
        #expect(loaded.historyRetentionDays == 90)
        #expect(loaded.hotkeys == persisted.hotkeys)
        #expect(try Data(contentsOf: store.fileURL) == persistedData)
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
        #expect(settings.applicationFormattingRules.isEmpty)
        #expect(settings.performanceMode == .adaptive)
        #expect(!settings.qualityAudioRetentionEnabled)
        #expect(settings.qualityAudioRetentionDays == 7)
        #expect(settings.qualityAudioMaximumBytes == 2_000_000_000)
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

    @Test
    func rejectsInvalidDuplicateAndUnboundedApplicationFormattingRules() {
        let terminal = ApplicationFormattingRule(
            bundleIdentifier: "com.apple.Terminal",
            applicationName: "Terminal",
            profile: .aiCommunication
        )
        #expect(throws: SettingsError.duplicateApplicationFormattingRule) {
            _ = try AppSettings(applicationFormattingRules: [
                terminal,
                ApplicationFormattingRule(
                    bundleIdentifier: "COM.APPLE.TERMINAL",
                    applicationName: "Terminal",
                    profile: .casual
                ),
            ]).validated()
        }
        #expect(throws: SettingsError.invalidApplicationFormattingRule) {
            _ = try AppSettings(applicationFormattingRules: [
                ApplicationFormattingRule(
                    bundleIdentifier: " com.apple.Terminal ",
                    applicationName: "Terminal",
                    profile: .casual
                ),
            ]).validated()
        }
        #expect(throws: SettingsError.tooManyApplicationFormattingRules) {
            _ = try AppSettings(applicationFormattingRules: (
                0...AppSettings.maximumApplicationFormattingRules
            ).map {
                ApplicationFormattingRule(
                    bundleIdentifier: "com.example.app\($0)",
                    applicationName: "App \($0)",
                    profile: .formatted
                )
            }).validated()
        }
    }
}
