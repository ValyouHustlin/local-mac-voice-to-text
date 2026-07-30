import ArgumentParser
import Foundation

/// Manage Wordhand's launch-at-login registration.
///
/// Only the signed release app may register through Apple's ServiceManagement
/// API. Development and command-line builds must never create persistence.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage launch at login for the signed Wordhand release app."
    )

    @Flag(name: .long, help: "Register wordhand to start at login.")
    var launchAtLogin: Bool = false

    @Flag(name: .long, help: "Remove the launch-at-login agent.")
    var uninstall: Bool = false

    func run() throws {
        if launchAtLogin == uninstall {
            FileHandle.standardError.write(Data(
                "specify exactly one of --launch-at-login or --uninstall\n".utf8
            ))
            throw ExitCode(64)
        }

        if uninstall {
            try removeAgent()
        } else {
            try writeAgent()
        }
    }

    // MARK: -

    private static let label = "com.valyou.wordhand"
    private static let legacyLabel = "com.digimata.parrot"

    private func writeAgent() throws {
        let loginManager = SystemLaunchAtLoginManager()
        guard loginManager.isAvailable else {
            FileHandle.standardError.write(Data(
                """
                Launch at login is disabled for development and command-line builds.
                Install a signed release app, then enable it from Wordhand Settings.

                """.utf8
            ))
            throw ExitCode(78)
        }

        try removeLegacyAgents()
        try loginManager.setEnabled(true)
        let state = loginManager.state()
        if state == .requiresApproval {
            loginManager.openSystemSettings()
            print("! Wordhand is registered but needs approval in Login Items")
        } else {
            print("✓ Wordhand will launch when you sign in")
        }
    }

    private func removeAgent() throws {
        let loginManager = SystemLaunchAtLoginManager()
        if loginManager.isAvailable {
            try loginManager.setEnabled(false)
            try removeLegacyAgents()
            print("✓ launch-at-login removed")
            return
        }

        try removeLegacyAgents()
        print("✓ legacy launch-at-login agents removed")
    }

    private func removeLegacyAgents() throws {
        for label in [Self.label, Self.legacyLabel] {
            let url = plistURL(for: label)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
            try FileManager.default.removeItem(at: url)
        }
    }

    private func plistURL(for label: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    private func uid() -> uid_t { getuid() }

    private func runLaunchctl(_ args: [String]) -> (status: Int32, stderr: String) {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = args
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()
        do {
            try task.run()
        } catch {
            return (-1, "\(error)")
        }
        task.waitUntilExit()
        let err = String(
            data: errPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (task.terminationStatus, err)
    }
}
