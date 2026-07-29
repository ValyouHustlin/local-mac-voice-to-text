import ArgumentParser
import Foundation

/// Manage Wordhand's launch-at-login registration.
///
/// Installed app bundles use Apple's ServiceManagement API. Source-built and
/// legacy command-line installations retain a LaunchAgent fallback.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install or remove the launch-at-login LaunchAgent."
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

    private var plistURL: URL {
        plistURL(for: Self.label)
    }

    private func writeAgent() throws {
        let loginManager = SystemLaunchAtLoginManager()
        if loginManager.isAvailable {
            try removeLegacyAgents()
            try loginManager.setEnabled(true)
            let state = loginManager.state()
            if state == .requiresApproval {
                loginManager.openSystemSettings()
                print("! Wordhand is registered but needs approval in Login Items")
            } else {
                print("✓ Wordhand will launch when you sign in")
            }
            return
        }

        let binary = try resolveBinaryPath()
        let legacyURL = plistURL(for: Self.legacyLabel)
        let hasLegacyAgent = FileManager.default.fileExists(atPath: legacyURL.path)
        if hasLegacyAgent {
            _ = runLaunchctl(["bootout", "gui/\(uid())", legacyURL.path])
        }

        let logDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Wordhand", isDirectory: true)
        try FileManager.default.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true
        )

        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [binary, "run", "--skip-doctor"],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": logDirectory.appendingPathComponent("stdout.log").path,
            "StandardErrorPath": logDirectory.appendingPathComponent("stderr.log").path,
        ]

        let url = plistURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)

        // Best-effort bootstrap; ignore failure if already loaded.
        _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
        let result = runLaunchctl(["bootstrap", "gui/\(uid())", url.path])
        if result.status != 0 {
            try? FileManager.default.removeItem(at: url)
            if hasLegacyAgent {
                _ = runLaunchctl(["bootstrap", "gui/\(uid())", legacyURL.path])
            }
            FileHandle.standardError.write(Data(
                "launchctl bootstrap exited \(result.status):\n\(result.stderr)\n".utf8
            ))
            throw ExitCode(1)
        }

        if hasLegacyAgent {
            try FileManager.default.removeItem(at: legacyURL)
            print("✓ removed legacy Parrot launch-at-login agent")
        }

        print("✓ launch-at-login installed")
        print("  plist:  \(url.path)")
        print("  binary: \(binary)")
        print("  logs:   \(logDirectory.path)")
    }

    private func removeAgent() throws {
        let loginManager = SystemLaunchAtLoginManager()
        if loginManager.isAvailable {
            try loginManager.setEnabled(false)
            try removeLegacyAgents()
            print("✓ launch-at-login removed")
            return
        }

        let url = plistURL
        if FileManager.default.fileExists(atPath: url.path) {
            _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
            try FileManager.default.removeItem(at: url)
            print("✓ launch-at-login removed")
        } else {
            print("nothing to remove (no agent at \(url.path))")
        }
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

    private func resolveBinaryPath() throws -> String {
        // /usr/local/bin/wordhand is the canonical install path. Honor a real
        // location if running from elsewhere (e.g. dev).
        let candidate = "/usr/local/bin/wordhand"
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // Fall back to the running executable's resolved path.
        let argv0 = CommandLine.arguments.first ?? "wordhand"
        if argv0.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: argv0) {
            FileHandle.standardError.write(Data(
                "note: /usr/local/bin/wordhand not found; using \(argv0)\n".utf8
            ))
            return argv0
        }
        FileHandle.standardError.write(Data(
            "couldn't locate the wordhand binary. install it to /usr/local/bin/wordhand first.\n".utf8
        ))
        throw ExitCode(1)
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
