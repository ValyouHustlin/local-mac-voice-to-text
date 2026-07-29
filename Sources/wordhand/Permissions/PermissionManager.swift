import AppKit
import ApplicationServices
import AVFoundation

enum MicrophonePermissionState: Equatable {
    case granted
    case notDetermined
    case denied
}

struct WordhandPermissionStatus: Equatable {
    var accessibilityGranted: Bool
    var microphone: MicrophonePermissionState

    var isReady: Bool {
        accessibilityGranted && microphone == .granted
    }
}

protocol PermissionManaging {
    func status() -> WordhandPermissionStatus
    func requestAccessibility()
    func requestMicrophone() async -> Bool
    func openAccessibilitySettings()
    func openMicrophoneSettings()
}

struct SystemPermissionManager: PermissionManaging {
    func status() -> WordhandPermissionStatus {
        let microphone: MicrophonePermissionState
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphone = .granted
        case .notDetermined:
            microphone = .notDetermined
        case .denied, .restricted:
            microphone = .denied
        @unknown default:
            microphone = .denied
        }
        return WordhandPermissionStatus(
            accessibilityGranted: AXIsProcessTrusted(),
            microphone: microphone
        )
    }

    func requestAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    func openMicrophoneSettings() {
        openPrivacyPane("Privacy_Microphone")
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
