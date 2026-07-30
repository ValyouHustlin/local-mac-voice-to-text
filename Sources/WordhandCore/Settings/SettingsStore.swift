import Foundation

public struct SettingsStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        ApplicationData.defaultDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("settings.json")
    }

    public func load() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return AppSettings()
        }
        try hardenPermissions()
        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        do {
            return try decoded.validated()
        } catch SettingsError.tooManyApplicationFormattingRules {
            return try decoded.withoutApplicationFormattingRules().validated()
        } catch SettingsError.invalidApplicationFormattingRule {
            return try decoded.withoutApplicationFormattingRules().validated()
        } catch SettingsError.duplicateApplicationFormattingRule {
            return try decoded.withoutApplicationFormattingRules().validated()
        }
    }

    public func save(_ settings: AppSettings) throws {
        let validated = try settings.validated()
        let data = try JSONEncoder.wordhand.encode(validated)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try hardenDirectoryPermissions()
        try data.write(to: fileURL, options: [.atomic])
        try hardenPermissions()
    }

    private func hardenDirectoryPermissions() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fileURL.deletingLastPathComponent().path
        )
    }

    private func hardenPermissions() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}

private extension AppSettings {
    func withoutApplicationFormattingRules() -> AppSettings {
        var recovered = self
        recovered.applicationFormattingRules = []
        return recovered
    }
}

private extension JSONEncoder {
    static var wordhand: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
