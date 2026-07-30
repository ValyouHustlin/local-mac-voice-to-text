import CoreML
import CryptoKit
import Foundation
import WhisperKit

struct ExactInferenceCacheStatistics: Codable, Equatable, Sendable {
    var hits: Int
    var misses: Int

    static let zero = ExactInferenceCacheStatistics(hits: 0, misses: 0)

    static func - (
        lhs: ExactInferenceCacheStatistics,
        rhs: ExactInferenceCacheStatistics
    ) -> ExactInferenceCacheStatistics {
        ExactInferenceCacheStatistics(
            hits: max(0, lhs.hits - rhs.hits),
            misses: max(0, lhs.misses - rhs.misses)
        )
    }
}

final class ExactFeatureCache: FeatureExtracting {
    private let base: any FeatureExtracting
    private let cache: ExactTensorCache

    var melCount: Int? { base.melCount }
    var windowSamples: Int? { base.windowSamples }
    var statistics: ExactInferenceCacheStatistics { cache.statistics }
    var entryCount: Int { cache.entryCount }

    init(
        base: any FeatureExtracting,
        maximumEntries: Int = 12
    ) {
        self.base = base
        self.cache = ExactTensorCache(maximumEntries: maximumEntries)
    }

    func beginSession() {
        cache.beginSession()
    }

    func endSession() {
        cache.endSession()
    }

    func logMelSpectrogram(
        fromAudio inputAudio: any AudioProcessorOutputType
    ) async throws -> (any FeatureExtractorOutputType)? {
        guard cache.isEnabled,
              let input = inputAudio as? MLMultiArray,
              let key = ExactTensorIdentity.sha256(input)
        else {
            return try await base.logMelSpectrogram(fromAudio: inputAudio)
        }
        if let cached = cache.value(for: key) {
            return cached
        }
        let output = try await base.logMelSpectrogram(fromAudio: inputAudio)
        if let output = output as? MLMultiArray {
            cache.insert(output, for: key)
        }
        return output
    }
}

final class ExactAudioEncoderCache: AudioEncoding {
    private let base: any AudioEncoding
    private let cache: ExactTensorCache

    var embedSize: Int? { base.embedSize }
    var statistics: ExactInferenceCacheStatistics { cache.statistics }
    var entryCount: Int { cache.entryCount }

    init(
        base: any AudioEncoding,
        maximumEntries: Int = 12
    ) {
        self.base = base
        self.cache = ExactTensorCache(maximumEntries: maximumEntries)
    }

    func beginSession() {
        cache.beginSession()
    }

    func endSession() {
        cache.endSession()
    }

    func encodeFeatures(
        _ features: any FeatureExtractorOutputType
    ) async throws -> (any AudioEncoderOutputType)? {
        guard cache.isEnabled,
              let input = features as? MLMultiArray,
              let key = ExactTensorIdentity.sha256(input)
        else {
            return try await base.encodeFeatures(features)
        }
        if let cached = cache.value(for: key) {
            return cached
        }
        let output = try await base.encodeFeatures(features)
        if let output = output as? MLMultiArray {
            cache.insert(output, for: key)
        }
        return output
    }
}

private final class ExactTensorCache {
    private let lock = NSLock()
    private let maximumEntries: Int
    private var enabled = false
    private var values: [String: MLMultiArray] = [:]
    private var order: [String] = []
    private var currentStatistics = ExactInferenceCacheStatistics.zero

    init(maximumEntries: Int) {
        self.maximumEntries = max(1, maximumEntries)
    }

    var isEnabled: Bool {
        lock.withLock { enabled }
    }

    var statistics: ExactInferenceCacheStatistics {
        lock.withLock { currentStatistics }
    }

    var entryCount: Int {
        lock.withLock { values.count }
    }

    func beginSession() {
        lock.withLock {
            enabled = true
            values.removeAll(keepingCapacity: true)
            order.removeAll(keepingCapacity: true)
            currentStatistics = .zero
        }
    }

    func endSession() {
        lock.withLock {
            enabled = false
            values.removeAll(keepingCapacity: true)
            order.removeAll(keepingCapacity: true)
            currentStatistics = .zero
        }
    }

    func value(for key: String) -> MLMultiArray? {
        lock.withLock {
            guard enabled else { return nil }
            guard let value = values[key] else {
                currentStatistics.misses += 1
                return nil
            }
            currentStatistics.hits += 1
            order.removeAll { $0 == key }
            order.append(key)
            return value
        }
    }

    func insert(_ value: MLMultiArray, for key: String) {
        lock.withLock {
            guard enabled else { return }
            values[key] = value
            order.removeAll { $0 == key }
            order.append(key)
            while order.count > maximumEntries {
                let evicted = order.removeFirst()
                values.removeValue(forKey: evicted)
            }
        }
    }
}

private enum ExactTensorIdentity {
    static func sha256(_ value: MLMultiArray) -> String? {
        guard let elementSize = byteCount(for: value.dataType) else {
            return nil
        }
        let shape = value.shape.map(\.intValue)
        let strides = value.strides.map(\.intValue)
        guard shape.count == strides.count,
              shape.allSatisfy({ $0 > 0 }),
              strides.allSatisfy({ $0 > 0 })
        else {
            return nil
        }
        let storageElementCount = zip(shape, strides).reduce(1) {
            $0 + ($1.0 - 1) * $1.1
        }
        guard storageElementCount > 0,
              storageElementCount <= Int.max / elementSize
        else {
            return nil
        }

        var hasher = SHA256()
        let metadata = [
            String(value.dataType.rawValue),
            shape.map(String.init).joined(separator: ","),
            strides.map(String.init).joined(separator: ",")
        ].joined(separator: "|")
        hasher.update(data: Data(metadata.utf8))
        hasher.update(data: Data(
            bytes: value.dataPointer,
            count: storageElementCount * elementSize
        ))
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func byteCount(
        for dataType: MLMultiArrayDataType
    ) -> Int? {
        switch dataType {
        case .double:
            return MemoryLayout<Double>.size
        case .float32:
            return MemoryLayout<Float>.size
        case .float16:
            return MemoryLayout<Float16>.size
        case .int32:
            return MemoryLayout<Int32>.size
        case .int8:
            return MemoryLayout<Int8>.size
        @unknown default:
            return nil
        }
    }
}
