import Foundation
import WordhandMobileCore

enum MobileConfiguration {
    static let appGroupIdentifier = "group.com.valyou.wordhand"
    static let callbackScheme = "wordhand"

    static func sharedTranscriptStore() throws -> SharedTranscriptStore {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw ConfigurationError.appGroupUnavailable
        }
        return SharedTranscriptStore(
            fileURL: container.appendingPathComponent(SharedTranscriptStore.fileName)
        )
    }

    static func benchmarkStore() throws -> LocalBenchmarkStore {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ConfigurationError.applicationSupportUnavailable
        }
        return LocalBenchmarkStore(
            rootDirectory: applicationSupport
                .appendingPathComponent("Wordhand", isDirectory: true)
                .appendingPathComponent("Benchmarks", isDirectory: true)
        )
    }
}

enum ConfigurationError: LocalizedError {
    case appGroupUnavailable
    case applicationSupportUnavailable

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "Wordhand's shared keyboard container is unavailable. Check the App Group entitlement."
        case .applicationSupportUnavailable:
            return "Wordhand could not open its private local storage."
        }
    }
}
