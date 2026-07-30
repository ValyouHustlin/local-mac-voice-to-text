import Foundation
import ServiceManagement

enum WordhandBundleIdentity {
    static let development = "com.valyou.wordhand.dev"
    static let release = "com.valyou.wordhand"
}

enum LaunchAtLoginState: Equatable {
    case unavailable
    case disabled
    case enabled
    case requiresApproval

    var isEnabled: Bool {
        self == .enabled
    }

    var canChange: Bool {
        self != .unavailable
    }

    var detail: String {
        switch self {
        case .unavailable:
            return "Launch at login is available in the signed release."
        case .disabled:
            return "Keep Wordhand ready without opening it manually."
        case .enabled:
            return "Wordhand starts automatically after you sign in."
        case .requiresApproval:
            return "Approve Wordhand in System Settings → General → Login Items."
        }
    }
}

protocol LaunchAtLoginManaging {
    var isAvailable: Bool { get }
    func state() -> LaunchAtLoginState
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

struct SystemLaunchAtLoginManager: LaunchAtLoginManaging {
    var isAvailable: Bool {
        Self.supportsRegistration(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            bundlePathExtension: Bundle.main.bundleURL.pathExtension
        )
    }

    static func supportsRegistration(
        bundleIdentifier: String?,
        bundlePathExtension: String
    ) -> Bool {
        bundlePathExtension == "app"
            && bundleIdentifier == WordhandBundleIdentity.release
    }

    func state() -> LaunchAtLoginState {
        guard isAvailable else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .notRegistered:
            return .disabled
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        guard isAvailable else {
            throw LaunchAtLoginError.requiresReleaseApplicationBundle
        }

        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            if service.status != .requiresApproval {
                try service.register()
            }
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

enum LaunchAtLoginError: LocalizedError {
    case requiresReleaseApplicationBundle

    var errorDescription: String? {
        switch self {
        case .requiresReleaseApplicationBundle:
            return "Launch at login is available only in a signed Wordhand release."
        }
    }
}
