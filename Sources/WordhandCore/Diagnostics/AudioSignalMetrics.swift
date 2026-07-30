import Foundation

public struct AudioSignalMetrics: Equatable, Sendable {
    public let sampleCount: Int
    public let rms: Double
    public let peak: Double
    public let clippedSampleFraction: Double
    public let activeWindowFraction: Double

    public static func measure(
        _ samples: [Float],
        sampleRate: Int,
        activityWindowSeconds: TimeInterval = 0.05
    ) -> AudioSignalMetrics {
        guard !samples.isEmpty, sampleRate > 0 else {
            return AudioSignalMetrics(
                sampleCount: samples.count,
                rms: 0,
                peak: 0,
                clippedSampleFraction: 0,
                activeWindowFraction: 0
            )
        }

        var sumOfSquares: Double = 0
        var peak: Float = 0
        var clippedSamples = 0
        for sample in samples {
            let magnitude = abs(sample)
            sumOfSquares += Double(sample * sample)
            peak = max(peak, magnitude)
            if magnitude >= 0.99 {
                clippedSamples += 1
            }
        }

        let windowSize = max(
            1,
            Int(activityWindowSeconds * Double(sampleRate))
        )
        var activeWindows = 0
        var windowCount = 0
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + windowSize)
            let window = samples[start..<end]
            var windowSquares: Double = 0
            var windowPeak: Float = 0
            for sample in window {
                windowSquares += Double(sample * sample)
                windowPeak = max(windowPeak, abs(sample))
            }
            let windowRMS = sqrt(windowSquares / Double(window.count))
            if windowRMS >= 0.003 || windowPeak >= 0.02 {
                activeWindows += 1
            }
            windowCount += 1
            start = end
        }

        return AudioSignalMetrics(
            sampleCount: samples.count,
            rms: sqrt(sumOfSquares / Double(samples.count)),
            peak: Double(peak),
            clippedSampleFraction:
                Double(clippedSamples) / Double(samples.count),
            activeWindowFraction: windowCount > 0
                ? Double(activeWindows) / Double(windowCount)
                : 0
        )
    }
}
