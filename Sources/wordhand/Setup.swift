import ApplicationServices
import ArgumentParser
import AVFoundation
import Foundation

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Walk through first-run permission setup."
    )

    func run() throws {
        print("wordhand setup")
        print("============")
        print()
        print("Wordhand needs three permissions:")
        print("  1. Accessibility — to insert text at the cursor.")
        print("  2. Input Monitoring — to detect Control-Space globally.")
        print("  3. Microphone — to record audio while you dictate.")
        print()
        print("These attach to your terminal app (Terminal/iTerm/Ghostty/etc.), not wordhand itself.")
        print()

        try waitForAccessibility()
        print()
        try waitForInputMonitoring()
        print()
        try waitForMicrophone()
        print()
        print("✓ all set. Run `wordhand` to start the daemon.")
    }

    private func waitForInputMonitoring() throws {
        if CGPreflightListenEventAccess() {
            print("✓ input monitoring already granted")
            return
        }

        print("→ requesting input monitoring access...")
        _ = CGRequestListenEventAccess()
        print()
        print("  1. Toggle Wordhand on in the Input Monitoring list.")
        print("  2. Quit and reopen Wordhand so macOS applies the grant.")
        throw ExitCode(0)
    }

    private func waitForAccessibility() throws {
        if AXIsProcessTrusted() {
            print("✓ accessibility already granted")
            return
        }

        print("→ opening accessibility prompt...")
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)

        print()
        print("  1. Toggle your terminal on in the Accessibility list.")
        print("  2. Re-run `wordhand setup` — macOS only picks up the grant on a fresh process.")
        throw ExitCode(0)
    }

    private func waitForMicrophone() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            print("✓ microphone already granted")
            return
        case .denied, .restricted:
            print("✗ microphone is denied — macOS won't re-prompt once denied.")
            print("  opening Settings → Privacy & Security → Microphone...")
            openSettings("Privacy_Microphone")
            print("  enable your terminal, then re-run `wordhand setup`.")
            throw ExitCode(1)
        case .notDetermined:
            print("→ requesting microphone access...")
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted = ok
                semaphore.signal()
            }
            semaphore.wait()
            if granted {
                print("  ✓ microphone granted")
            } else {
                print("  ✗ microphone denied")
                throw ExitCode(1)
            }
        @unknown default:
            print("? microphone in unknown state")
        }
    }

    private func openSettings(_ pane: String) {
        let url = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [url]
        try? task.run()
    }
}
