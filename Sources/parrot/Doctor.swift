import AVFoundation
import AppKit
import ApplicationServices
import Foundation

enum CheckStatus {
    case ok
    case warn(String)
    case fail(String)
}

struct Check {
    let name: String
    let status: CheckStatus
    let remediation: String?
}

enum DoctorReport {
    static func run() -> [Check] {
        [
            checkMicrophone(),
            checkAccessibility(),
            checkControlSpaceAvailability(),
        ]
    }

    static func checkMicrophone() -> Check {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return Check(name: "microphone", status: .ok, remediation: nil)
        case .notDetermined:
            return Check(
                name: "microphone",
                status: .warn("not yet requested — will prompt on first recording"),
                remediation: "run parrot and hold Control-Space once; macOS will prompt"
            )
        case .denied, .restricted:
            return Check(
                name: "microphone",
                status: .fail("denied"),
                remediation: "System Settings → Privacy & Security → Microphone → enable for your terminal"
            )
        @unknown default:
            return Check(name: "microphone", status: .fail("unknown state"), remediation: nil)
        }
    }

    static func checkAccessibility() -> Check {
        if AXIsProcessTrusted() {
            return Check(name: "accessibility", status: .ok, remediation: nil)
        }
        let parent = parentProcessName() ?? "your terminal"
        return Check(
            name: "accessibility",
            status: .fail("not granted"),
            remediation: "System Settings → Privacy & Security → Accessibility → enable for \(parent)"
        )
    }

    /// Shortcut 60 is macOS's "Select the previous input source" binding,
    /// whose default key combination is Control-Space.
    static func checkControlSpaceAvailability() -> Check {
        guard
            let domain = UserDefaults.standard.persistentDomain(
                forName: "com.apple.symbolichotkeys"
            ),
            let shortcuts = domain["AppleSymbolicHotKeys"] as? [String: Any],
            let inputSource = shortcuts["60"] as? [String: Any],
            let enabled = inputSource["enabled"] as? Bool
        else {
            return Check(
                name: "Control-Space",
                status: .warn("could not inspect the macOS input-source shortcut"),
                remediation: "System Settings → Keyboard → Keyboard Shortcuts → Input Sources"
            )
        }
        guard enabled else {
            return Check(name: "Control-Space", status: .ok, remediation: nil)
        }
        return Check(
            name: "Control-Space",
            status: .fail("reserved by the macOS input-source shortcut"),
            remediation: "System Settings → Keyboard → Keyboard Shortcuts → Input Sources → disable Select the previous input source"
        )
    }

    private static func parentProcessName() -> String? {
        let ppid = getppid()
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-p", String(ppid), "-o", "comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        return (s as NSString).lastPathComponent
    }

    static func print(_ checks: [Check]) {
        for c in checks {
            let (mark, label): (String, String) = {
                switch c.status {
                case .ok: return ("✓", "ok")
                case .warn(let msg): return ("!", msg)
                case .fail(let msg): return ("✗", msg)
                }
            }()
            Swift.print("\(mark) \(c.name): \(label)")
            if let r = c.remediation {
                Swift.print("    → \(r)")
            }
        }
    }

    /// True if no checks are in a hard-fail state. Warnings don't block.
    static func allOK(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .fail = $0.status { return false }
            return true
        }
    }

    /// True only if every check passed cleanly (used by `parrot doctor` exit code).
    static func allClean(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .ok = $0.status { return true }
            return false
        }
    }
}
