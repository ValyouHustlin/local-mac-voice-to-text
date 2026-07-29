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
    public var keyCode: UInt16
    public var modifiers: [String]
    public var action: Action

    public init(
        key: String,
        keyCode: UInt16? = nil,
        modifiers: [String] = [],
        action: Action
    ) {
        self.key = key
        self.keyCode = keyCode ?? Self.legacyKeyCode(for: key) ?? 49
        self.modifiers = modifiers
        self.action = action
    }

    public var resolvedModifiers: Set<HotkeyModifier> {
        Set(modifiers.compactMap(HotkeyModifier.init(rawValue:)))
    }

    public var displayName: String {
        let ordered: [(HotkeyModifier, String)] = [
            (.control, "⌃"),
            (.option, "⌥"),
            (.shift, "⇧"),
            (.command, "⌘"),
            (.function, "fn "),
        ]
        let modifierText = ordered
            .filter { resolvedModifiers.contains($0.0) }
            .map(\.1)
            .joined()
        return modifierText + Self.displayKeyName(key)
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case keyCode
        case modifiers
        case action
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        keyCode = try container.decodeIfPresent(UInt16.self, forKey: .keyCode)
            ?? Self.legacyKeyCode(for: key)
            ?? 49
        modifiers = try container.decode([String].self, forKey: .modifiers)
        action = try container.decode(Action.self, forKey: .action)
    }

    private static func legacyKeyCode(for key: String) -> UInt16? {
        let normalized = key.lowercased()
        let known: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5,
            "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
            "return": 36, "l": 37, "j": 38, "'": 39, "k": 40,
            ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
            "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
            "delete": 51, "escape": 53, "left": 123, "right": 124,
            "down": 125, "up": 126,
        ]
        return known[normalized]
    }

    private static func displayKeyName(_ key: String) -> String {
        switch key.lowercased() {
        case "space": return "Space"
        case "return": return "Return"
        case "tab": return "Tab"
        case "delete": return "Delete"
        case "escape": return "Escape"
        case "left": return "←"
        case "right": return "→"
        case "down": return "↓"
        case "up": return "↑"
        default: return key.uppercased()
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var modelID: String
    public var insertionMode: InsertionMode
    public var showOverlay: Bool
    public var soundEffectsEnabled: Bool
    public var formattingProfile: TranscriptFormattingProfile
    public var historyRetentionDays: Int
    public var hotkeys: [HotkeyBinding]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        modelID: String = "whisper-large-v3",
        insertionMode: InsertionMode = .paste,
        showOverlay: Bool = true,
        soundEffectsEnabled: Bool = true,
        formattingProfile: TranscriptFormattingProfile = .automatic,
        historyRetentionDays: Int = 30,
        hotkeys: [HotkeyBinding] = [
            HotkeyBinding(key: "space", modifiers: ["control"], action: .pushToTalk),
        ]
    ) {
        self.schemaVersion = schemaVersion
        self.modelID = modelID
        self.insertionMode = insertionMode
        self.showOverlay = showOverlay
        self.soundEffectsEnabled = soundEffectsEnabled
        self.formattingProfile = formattingProfile
        self.historyRetentionDays = historyRetentionDays
        self.hotkeys = hotkeys
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case modelID
        case insertionMode
        case showOverlay
        case soundEffectsEnabled
        case formattingProfile
        case historyRetentionDays
        case hotkeys
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        modelID = try container.decode(String.self, forKey: .modelID)
        insertionMode = try container.decode(InsertionMode.self, forKey: .insertionMode)
        showOverlay = try container.decode(Bool.self, forKey: .showOverlay)
        soundEffectsEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .soundEffectsEnabled
        ) ?? true
        formattingProfile = try container.decodeIfPresent(
            TranscriptFormattingProfile.self,
            forKey: .formattingProfile
        ) ?? .automatic
        historyRetentionDays = try container.decode(Int.self, forKey: .historyRetentionDays)
        hotkeys = try container.decode([HotkeyBinding].self, forKey: .hotkeys)
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
        var shortcuts = Set<String>()
        for hotkey in hotkeys {
            guard
                !hotkey.modifiers.isEmpty,
                hotkey.resolvedModifiers.count == hotkey.modifiers.count
            else {
                throw SettingsError.invalidHotkey
            }
            let modifierKey = hotkey.resolvedModifiers
                .map(\.rawValue)
                .sorted()
                .joined(separator: "+")
            let shortcutKey = "\(hotkey.keyCode):\(modifierKey)"
            guard shortcuts.insert(shortcutKey).inserted else {
                throw SettingsError.duplicateHotkey
            }
        }
        return self
    }
}

public enum SettingsError: Error, Equatable {
    case unsupportedSchema(Int)
    case unknownModel(String)
    case invalidRetentionDays(Int)
    case invalidHotkeys
    case invalidHotkey
    case duplicateHotkey
}
