import CoreML
import Testing
import WhisperKit
@testable import wordhand

@Suite
struct ExactInferenceCacheTests {
    @Test
    func featureCacheReusesOnlyAnExactTensorAndResetRevokesIt() async throws {
        let base = CountingFeatureExtractor()
        let cache = ExactFeatureCache(base: base, maximumEntries: 2)
        let first = try tensor([1, 2, 3, 4])
        let identical = try tensor([1, 2, 3, 4])
        let changed = try tensor([1, 2, 3, 5])

        cache.beginSession()
        _ = try await cache.logMelSpectrogram(fromAudio: first)
        _ = try await cache.logMelSpectrogram(fromAudio: identical)
        _ = try await cache.logMelSpectrogram(fromAudio: changed)

        #expect(base.callCount == 2)
        #expect(cache.statistics == .init(hits: 1, misses: 2))

        cache.endSession()
        cache.beginSession()
        _ = try await cache.logMelSpectrogram(fromAudio: identical)

        #expect(base.callCount == 3)
        #expect(cache.statistics == .init(hits: 0, misses: 1))
    }

    @Test
    func encoderCacheReusesOnlyAnExactTensorAndIsBounded() async throws {
        let base = CountingAudioEncoder()
        let cache = ExactAudioEncoderCache(base: base, maximumEntries: 2)

        cache.beginSession()
        _ = try await cache.encodeFeatures(try tensor([1, 1]))
        _ = try await cache.encodeFeatures(try tensor([2, 2]))
        _ = try await cache.encodeFeatures(try tensor([3, 3]))
        _ = try await cache.encodeFeatures(try tensor([1, 1]))
        _ = try await cache.encodeFeatures(try tensor([3, 3]))

        #expect(base.callCount == 4)
        #expect(cache.statistics == .init(hits: 1, misses: 4))
        #expect(cache.entryCount == 2)
    }

    @Test
    func disabledCacheIsTransparentAndRecordsNoClaims() async throws {
        let featureBase = CountingFeatureExtractor()
        let featureCache = ExactFeatureCache(base: featureBase)
        let encoderBase = CountingAudioEncoder()
        let encoderCache = ExactAudioEncoderCache(base: encoderBase)
        let input = try tensor([7, 8])

        _ = try await featureCache.logMelSpectrogram(fromAudio: input)
        _ = try await featureCache.logMelSpectrogram(fromAudio: input)
        _ = try await encoderCache.encodeFeatures(input)
        _ = try await encoderCache.encodeFeatures(input)

        #expect(featureBase.callCount == 2)
        #expect(encoderBase.callCount == 2)
        #expect(featureCache.statistics == .zero)
        #expect(encoderCache.statistics == .zero)
    }

    private func tensor(_ values: [Float]) throws -> MLMultiArray {
        let result = try MLMultiArray(
            shape: [NSNumber(value: values.count)],
            dataType: .float32
        )
        for (index, value) in values.enumerated() {
            result[index] = NSNumber(value: value)
        }
        return result
    }
}

private final class CountingFeatureExtractor: FeatureExtracting {
    var melCount: Int? = 1
    var windowSamples: Int? = 4
    private(set) var callCount = 0

    func logMelSpectrogram(
        fromAudio inputAudio: any AudioProcessorOutputType
    ) async throws -> (any FeatureExtractorOutputType)? {
        callCount += 1
        return inputAudio as? MLMultiArray
    }
}

private final class CountingAudioEncoder: AudioEncoding {
    var embedSize: Int? = 1
    private(set) var callCount = 0

    func encodeFeatures(
        _ features: any FeatureExtractorOutputType
    ) async throws -> (any AudioEncoderOutputType)? {
        callCount += 1
        return features as? MLMultiArray
    }
}
