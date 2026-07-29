import Foundation

public enum InsertionMode: String, Codable, CaseIterable, Sendable {
    case paste
    case unicode
    case copyOnly
}

public struct HotkeyBinding: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case pushToTalk
        case toggleRecording
        case copyLastTranscript
        case openHistory
        case undoLastInsertion
    }

    public var key: String
    public var modifiers: [String]
    public var action: Action

    public init(key: String, modifiers: [String] = [], action: Action) {
        self.key = key
        self.modifiers = modifiers
        self.action = action
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var modelID: String
    public var insertionMode: InsertionMode
    public var showOverlay: Bool
    public var historyRetentionDays: Int
    public var hotkeys: [HotkeyBinding]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        modelID: String = "whisper-base.en",
        insertionMode: InsertionMode = .paste,
        showOverlay: Bool = true,
        historyRetentionDays: Int = 30,
        hotkeys: [HotkeyBinding] = [
            HotkeyBinding(key: "space", modifiers: ["control"], action: .pushToTalk),
        ]
    ) {
        self.schemaVersion = schemaVersion
        self.modelID = modelID
        self.insertionMode = insertionMode
        self.showOverlay = showOverlay
        self.historyRetentionDays = historyRetentionDays
        self.hotkeys = hotkeys
    }

    public func validated() throws -> AppSettings {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SettingsError.unsupportedSchema(schemaVersion)
        }
        guard ModelRegistry.find(modelID) != nil else {
            throw SettingsError.unknownModel(modelID)
        }
        guard (1...3_650).contains(historyRetentionDays) else {
            throw SettingsError.invalidRetentionDays(historyRetentionDays)
        }
        guard !hotkeys.isEmpty, hotkeys.allSatisfy({ !$0.key.isEmpty }) else {
            throw SettingsError.invalidHotkeys
        }
        return self
    }
}

public enum SettingsError: Error, Equatable {
    case unsupportedSchema(Int)
    case unknownModel(String)
    case invalidRetentionDays(Int)
    case invalidHotkeys
}
