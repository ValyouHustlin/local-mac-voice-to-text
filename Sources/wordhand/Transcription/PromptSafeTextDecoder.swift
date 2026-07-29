import CoreML
import Foundation
import WhisperKit
import WordhandCore

/// WhisperKit 1.0 lets a sampled end token or first-token confidence check
/// terminate decoding while it is still forcing `promptTokens`. Large models
/// commonly sample end-of-text at that stage, returning an empty transcript.
/// This adapter preserves WhisperKit's decoder while deferring stop decisions
/// until the forced prompt has been consumed.
final class PromptSafeTextDecoder: TextDecoding, WhisperMLModel {
    private let decoder = TextDecoder()

    var model: MLModel? {
        get { decoder.model }
        set { decoder.model = newValue }
    }

    var tokenizer: WhisperTokenizer? {
        get { decoder.tokenizer }
        set { decoder.tokenizer = newValue }
    }

    var isModelMultilingual: Bool {
        get { decoder.isModelMultilingual }
        set { decoder.isModelMultilingual = newValue }
    }

    var supportsWordTimestamps: Bool { decoder.supportsWordTimestamps }
    var logitsSize: Int? { decoder.logitsSize }
    var kvCacheEmbedDim: Int? { decoder.kvCacheEmbedDim }
    var kvCacheMaxSequenceLength: Int? { decoder.kvCacheMaxSequenceLength }
    var windowSize: Int? { decoder.windowSize }
    var embedSize: Int? { decoder.embedSize }

    var logitsFilters: [any LogitsFiltering]? {
        get { decoder.logitsFilters }
        set { decoder.logitsFilters = newValue }
    }

    func predictLogits(
        _ inputs: any TextDecoderInputType
    ) async throws -> TextDecoderOutputType? {
        try await decoder.predictLogits(inputs)
    }

    func prepareDecoderInputs(
        withPrompt initialPrompt: [Int]
    ) throws -> any DecodingInputsType {
        try decoder.prepareDecoderInputs(withPrompt: initialPrompt)
    }

    func prefillDecoderInputs(
        _ decoderInputs: any DecodingInputsType,
        withOptions options: DecodingOptions?
    ) async throws -> any DecodingInputsType {
        try await decoder.prefillDecoderInputs(decoderInputs, withOptions: options)
    }

    func decodeText(
        from encoderOutput: any AudioEncoderOutputType,
        using decoderInputs: any DecodingInputsType,
        sampler tokenSampler: TokenSampling,
        options: DecodingOptions,
        callback: TranscriptionCallback?
    ) async throws -> DecodingResult {
        let forcedTokenCount = max(
            0,
            decoderInputs.initialPrompt.count
                - decoderInputs.cacheLength[0].intValue
                - 1
        )
        guard options.promptTokens != nil, forcedTokenCount > 0 else {
            return try await decoder.decodeText(
                from: encoderOutput,
                using: decoderInputs,
                sampler: tokenSampler,
                options: options,
                callback: callback
            )
        }

        let guardedSampler = PromptPrefillTokenSampler(
            sampler: tokenSampler,
            forcedTokenCount: forcedTokenCount,
            firstOutputLogProbabilityThreshold: options.firstTokenLogProbThreshold
        )
        return try await decoder.decodeText(
            from: encoderOutput,
            using: decoderInputs,
            sampler: guardedSampler,
            options: options,
            callback: callback
        )
    }

    func detectLanguage(
        from encoderOutput: any AudioEncoderOutputType,
        using decoderInputs: any DecodingInputsType,
        sampler tokenSampler: TokenSampling,
        options: DecodingOptions,
        temperature: FloatType
    ) async throws -> DecodingResult {
        try await decoder.detectLanguage(
            from: encoderOutput,
            using: decoderInputs,
            sampler: tokenSampler,
            options: options,
            temperature: temperature
        )
    }

    static func updateKVCache(
        keyTensor: MLMultiArray,
        keySlice: MLMultiArray,
        valueTensor: MLMultiArray,
        valueSlice: MLMultiArray,
        insertAtIndex index: Int
    ) {
        TextDecoder.updateKVCache(
            keyTensor: keyTensor,
            keySlice: keySlice,
            valueTensor: valueTensor,
            valueSlice: valueSlice,
            insertAtIndex: index
        )
    }
}

private final class PromptPrefillTokenSampler: TokenSampling, @unchecked Sendable {
    private let sampler: TokenSampling
    private let gate: DecoderPromptPrefillGate
    private let firstOutputLogProbabilityThreshold: Float?

    init(
        sampler: TokenSampling,
        forcedTokenCount: Int,
        firstOutputLogProbabilityThreshold: Float?
    ) {
        self.sampler = sampler
        gate = DecoderPromptPrefillGate(forcedTokenCount: forcedTokenCount)
        self.firstOutputLogProbabilityThreshold = firstOutputLogProbabilityThreshold
    }

    func update(
        tokens: [Int],
        logits: MLMultiArray,
        logProbs: [Float]
    ) async -> SamplingResult {
        var result = await sampler.update(
            tokens: tokens,
            logits: logits,
            logProbs: logProbs
        )
        let lastLogProbability = result.logProbs.last ?? 0
        let decision = gate.evaluate(
            sampledCompletion: result.completed,
            sampledLogProbability: lastLogProbability,
            firstOutputLogProbabilityThreshold: firstOutputLogProbabilityThreshold
        )
        result.completed = decision.shouldComplete
        if !result.logProbs.isEmpty {
            result.logProbs[result.logProbs.count - 1] =
                decision.effectiveLogProbability
        }
        return result
    }

    func finalize(tokens: [Int], logProbs: [Float]) -> SamplingResult {
        sampler.finalize(tokens: tokens, logProbs: logProbs)
    }
}
