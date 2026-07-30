import AppKit
import Foundation

enum ApplicationRelaunchError: LocalizedError {
    case notApplicationBundle

    var errorDescription: String? {
        switch self {
        case .notApplicationBundle:
            return "the running executable is not inside an application bundle"
        }
    }
}

enum ApplicationRelauncher {
    @MainActor
    static func relaunchCurrentApplication() throws {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            throw ApplicationRelaunchError.notApplicationBundle
        }

        // A tiny detached helper waits for the current process to exit and
        // release its single-instance lock, then asks LaunchServices to reopen
        // the same signed bundle. Values are passed as data, not interpolated
        // into the shell program.
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            """
            attempts=0
            while /bin/kill -0 "$WORDHAND_RELAUNCH_PID" 2>/dev/null \
                && [ "$attempts" -lt 100 ]; do
                /bin/sleep 0.1
                attempts=$((attempts + 1))
            done
            if /bin/kill -0 "$WORDHAND_RELAUNCH_PID" 2>/dev/null; then
                exit 1
            fi
            /usr/bin/open "$WORDHAND_RELAUNCH_BUNDLE"
            """,
        ]
        helper.environment = [
            "WORDHAND_RELAUNCH_BUNDLE": bundleURL.path,
            "WORDHAND_RELAUNCH_PID": String(ProcessInfo.processInfo.processIdentifier),
        ]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()

        NSApplication.shared.terminate(nil)
    }
}
