import Foundation

public struct DecoderPromptPrefillDecision: Equatable, Sendable {
    public let shouldComplete: Bool
    public let effectiveLogProbability: Float

    public init(shouldComplete: Bool, effectiveLogProbability: Float) {
        self.shouldComplete = shouldComplete
        self.effectiveLogProbability = effectiveLogProbability
    }
}

public final class DecoderPromptPrefillGate: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingForcedTokens: Int
    private var hasEvaluatedFirstOutput = false

    public init(forcedTokenCount: Int) {
        remainingForcedTokens = max(0, forcedTokenCount)
    }

    public func evaluate(
        sampledCompletion: Bool,
        sampledLogProbability: Float,
        firstOutputLogProbabilityThreshold: Float?
    ) -> DecoderPromptPrefillDecision {
        lock.withLock {
            if remainingForcedTokens > 0 {
                remainingForcedTokens -= 1
                return DecoderPromptPrefillDecision(
                    shouldComplete: false,
                    effectiveLogProbability: max(
                        sampledLogProbability,
                        firstOutputLogProbabilityThreshold ?? sampledLogProbability
                    )
                )
            }

            let isFirstOutput = !hasEvaluatedFirstOutput
            hasEvaluatedFirstOutput = true
            let firstOutputIsTooUnlikely =
                if isFirstOutput,
                   let threshold = firstOutputLogProbabilityThreshold
                {
                    sampledLogProbability < threshold
                } else {
                    false
                }
            return DecoderPromptPrefillDecision(
                shouldComplete: sampledCompletion || firstOutputIsTooUnlikely,
                effectiveLogProbability: sampledLogProbability
            )
        }
    }
}
