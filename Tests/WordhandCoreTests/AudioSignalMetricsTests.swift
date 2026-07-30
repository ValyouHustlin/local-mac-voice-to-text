import Testing
@testable import WordhandCore

@Suite
struct AudioSignalMetricsTests {
    @Test
    func summarizesSignalHealthWithoutRetainingSamples() {
        let samples: [Float] = [
            0, 0, 0.5, -0.5, 1, -1, 0.25, -0.25,
        ]

        let metrics = AudioSignalMetrics.measure(
            samples,
            sampleRate: 8,
            activityWindowSeconds: 0.5
        )

        #expect(metrics.sampleCount == 8)
        #expect(metrics.peak == 1)
        #expect(metrics.clippedSampleFraction == 0.25)
        #expect(metrics.rms > 0.5)
        #expect(metrics.activeWindowFraction == 1)
    }

    @Test
    func emptySignalHasZeroHealthMetrics() {
        let metrics = AudioSignalMetrics.measure([], sampleRate: 16_000)

        #expect(metrics.sampleCount == 0)
        #expect(metrics.rms == 0)
        #expect(metrics.peak == 0)
        #expect(metrics.activeWindowFraction == 0)
    }
}
