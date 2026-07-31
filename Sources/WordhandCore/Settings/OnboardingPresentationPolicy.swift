public struct OnboardingReadiness: Equatable, Sendable {
    public let accessibilityGranted: Bool
    public let inputMonitoringGranted: Bool
    public let microphoneGranted: Bool
    public let modelReady: Bool

    public init(
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool,
        microphoneGranted: Bool,
        modelReady: Bool
    ) {
        self.accessibilityGranted = accessibilityGranted
        self.inputMonitoringGranted = inputMonitoringGranted
        self.microphoneGranted = microphoneGranted
        self.modelReady = modelReady
    }

    public var canFinish: Bool {
        accessibilityGranted
            && inputMonitoringGranted
            && microphoneGranted
            && modelReady
    }
}

public enum OnboardingPresentationPolicy {
    public static let currentVersion = 1

    public static func shouldPresent(
        isBundledApplication: Bool,
        completedVersion: Int
    ) -> Bool {
        isBundledApplication && completedVersion < currentVersion
    }
}
