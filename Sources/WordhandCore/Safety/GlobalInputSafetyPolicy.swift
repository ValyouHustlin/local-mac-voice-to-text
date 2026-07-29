import Foundation

public enum GlobalInputSafetyPolicy {
    public static let safeModeEnvironmentKey = "WORDHAND_SAFE"
    public static let maximumDevelopmentTestSeconds = 30

    public static func blocksGlobalInput(environment: [String: String]) -> Bool {
        guard let rawValue = environment[safeModeEnvironmentKey] else {
            return false
        }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    public static func validatedDevelopmentTestTimeout(
        optedIn: Bool,
        timeoutSeconds: Int?
    ) -> Int? {
        guard optedIn, let timeoutSeconds else { return nil }
        guard (1...maximumDevelopmentTestSeconds).contains(timeoutSeconds) else {
            return nil
        }
        return timeoutSeconds
    }

    public static func hasInvalidDevelopmentTestConfiguration(
        optedIn: Bool,
        timeoutSeconds: Int?
    ) -> Bool {
        if optedIn != (timeoutSeconds != nil) {
            return true
        }
        guard optedIn else { return false }
        return validatedDevelopmentTestTimeout(
            optedIn: optedIn,
            timeoutSeconds: timeoutSeconds
        ) == nil
    }

}
