import Foundation

public enum ApplicationData {
    public static let currentDirectoryName = "Wordhand"
    public static let legacyDirectoryName = "Parrot"

    public static func defaultDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(currentDirectoryName, isDirectory: true)
    }

    public static func legacyDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(legacyDirectoryName, isDirectory: true)
    }

    /// Copies the pre-Wordhand application data into the branded directory once.
    ///
    /// The legacy directory is intentionally preserved as a rollback path. Copying
    /// through a staging directory prevents a failed migration from leaving a
    /// partial destination that would suppress the next attempt.
    @discardableResult
    public static func migrateLegacyDataIfNeeded(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> Bool {
        let source = legacyDirectory(homeDirectory: homeDirectory)
        let destination = defaultDirectory(homeDirectory: homeDirectory)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              !fileManager.fileExists(atPath: destination.path)
        else {
            return false
        }

        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        let staging = parent.appendingPathComponent(
            ".Wordhand-migration-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
        }

        try fileManager.copyItem(at: source, to: staging)
        try fileManager.moveItem(at: staging, to: destination)
        return true
    }
}
