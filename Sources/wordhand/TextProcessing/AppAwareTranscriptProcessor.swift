import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import WordhandCore

struct LocalTranscriptRewriteRequest: Sendable {
    let text: String
    let sessionInstructions: String
    let promptPrefix: String
    let dynamicConstraints: String
    let maximumResponseTokens: Int
    let timeoutSeconds: UInt64
}

struct LocalTranscriptRewriteResult: Sendable {
    let text: String
}

protocol LocalTranscriptRewriting: Sendable {
    func prewarm(
        sessionInstructions: String,
        promptPrefix: String
    ) async
    func rewrite(
        _ request: LocalTranscriptRewriteRequest
    ) async throws -> LocalTranscriptRewriteResult
}

extension LocalTranscriptRewriting {
    func prewarm(
        sessionInstructions: String,
        promptPrefix: String
    ) async {}
}

final class AppAwareTranscriptProcessor:
    ContextualReportingTranscriptProcessing,
    @unchecked Sendable
{
    private let dictionaryProcessor: MutableTranscriptProcessor
    private let rewriter: any LocalTranscriptRewriting
    private let lock = NSLock()
    private var profile: TranscriptFormattingProfile
    private var applicationRules: [ApplicationFormattingRule]
    private var performanceMode: ProcessingPerformanceMode

    init(
        dictionaryProcessor: MutableTranscriptProcessor,
        profile: TranscriptFormattingProfile,
        applicationRules: [ApplicationFormattingRule] = [],
        performanceMode: ProcessingPerformanceMode = .adaptive,
        rewriter: any LocalTranscriptRewriting = FoundationModelTranscriptRewriter()
    ) {
        self.dictionaryProcessor = dictionaryProcessor
        self.profile = profile
        self.applicationRules = applicationRules
        self.performanceMode = performanceMode
        self.rewriter = rewriter
    }

    func update(
        profile: TranscriptFormattingProfile,
        applicationRules: [ApplicationFormattingRule]? = nil,
        performanceMode: ProcessingPerformanceMode? = nil
    ) {
        lock.withLock {
            self.profile = profile
            if let applicationRules {
                self.applicationRules = applicationRules
            }
            if let performanceMode {
                self.performanceMode = performanceMode
            }
        }
    }

    func prepare(target: TranscriptTarget) async {
        await prepare(context: context(for: target))
    }

    func prepare(context: TranscriptProcessingContext) async {
        let fallback = resolvedConfiguration(for: context.target)
        let profile = context.formattingProfile ?? fallback.0.profile
        let performanceMode = context.performanceMode ?? fallback.1
        guard performanceMode == .adaptive else { return }
        guard let intent = TranscriptRewriteIntent(profile: profile) else {
            return
        }
        await rewriter.prewarm(
            sessionInstructions: intent.instructions(for: context.target),
            promptPrefix: Self.rewritePromptPrefix
        )
    }

    func process(_ text: String, target: TranscriptTarget) async -> String {
        await processResult(text, context: context(for: target)).text
    }

    func processResult(
        _ text: String,
        target: TranscriptTarget
    ) async -> TranscriptProcessingResult {
        await processResult(text, context: context(for: target))
    }

    func process(
        _ text: String,
        context: TranscriptProcessingContext
    ) async -> String {
        await processResult(text, context: context).text
    }

    func processResult(
        _ text: String,
        context: TranscriptProcessingContext
    ) async -> TranscriptProcessingResult {
        let cleaned = await dictionaryProcessor.process(
            text,
            target: context.target
        )
        let replacement = SpokenReplacementCommandEngine.apply(to: cleaned)
        if case .rejected(let reason) = replacement.outcome {
            return TranscriptProcessingResult(
                text: replacement.text,
                notices: [.spokenReplacementRejected(reason)]
            )
        }
        let layout = SpokenLayoutCommandEngine.protect(replacement.text)
        let selectedProfile = context.formattingProfile
            ?? resolvedProfile(for: context.target)
        let selectedPerformanceMode = context.performanceMode
            ?? resolvedConfiguration(for: context.target).1

        let formatted: String
        switch selectedProfile {
        case .casual:
            formatted = TranscriptProcessor.polish(layout.protectedText)
        case .formatted:
            formatted = selectedPerformanceMode == .maximum
                ? fallback(layout.protectedText, for: .formatted)
                : await rewrite(
                    layout.protectedText,
                    intent: .formatted,
                    target: context.target,
                    layout: layout
                )
        case .professional:
            formatted = selectedPerformanceMode == .maximum
                ? fallback(layout.protectedText, for: .professional)
                : await rewrite(
                    layout.protectedText,
                    intent: .professional,
                    target: context.target,
                    layout: layout
                )
        case .aiCommunication:
            formatted = selectedPerformanceMode == .maximum
                ? fallback(layout.protectedText, for: .aiCommunication)
                : await rewrite(
                    layout.protectedText,
                    intent: .aiCommunication,
                    target: context.target,
                    layout: layout
                )
        }
        return TranscriptProcessingResult(
            text: layout.render(formatted),
            notices: []
        )
    }

    func context(for target: TranscriptTarget) -> TranscriptProcessingContext {
        let configuration = resolvedConfiguration(for: target)
        return TranscriptProcessingContext(
            target: target,
            formattingProfile: configuration.0.profile,
            formattingRouteSource: configuration.0.source,
            performanceMode: configuration.1
        )
    }

    func resolvedProfile(for target: TranscriptTarget) -> TranscriptFormattingProfile {
        resolvedConfiguration(for: target).0.profile
    }

    private func resolvedConfiguration(
        for target: TranscriptTarget
    ) -> (ResolvedApplicationFormattingProfile, ProcessingPerformanceMode) {
        lock.withLock {
            (
                ApplicationFormattingProfileRouter.resolve(
                    default: profile,
                    rules: applicationRules,
                    target: target
                ),
                performanceMode
            )
        }
    }

    private func rewrite(
        _ text: String,
        intent: TranscriptRewriteIntent,
        target: TranscriptTarget,
        layout: SpokenLayoutCommandPlan
    ) async -> String {
        guard !text.isEmpty else { return text }
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        let responseTokens = min(768, max(128, wordCount * 3))
        let meaningMarkers = TranscriptRewriteValidator.requiredMeaningMarkers(in: text)
            .sorted()
            .joined(separator: ", ")
        var dynamicConstraints = ""
        if layout.commandCount > 0 {
            dynamicConstraints += """

            The source contains \(layout.commandCount) opaque WORDHAND_LAYOUT tokens.
            Keep every token exactly once, in the same order and position between the surrounding thoughts.
            Do not punctuate, rename, explain, or remove those tokens.
            """
        }
        if !meaningMarkers.isEmpty {
            dynamicConstraints += """

            The source contains these meaning markers: \(meaningMarkers).
            Retain every one in the rewrite. They encode speaker perspective, modality, or requested action.
            """
        }

        do {
            let candidate = try await rewriter.rewrite(
                LocalTranscriptRewriteRequest(
                    text: text,
                    sessionInstructions: intent.instructions(for: target),
                    promptPrefix: Self.rewritePromptPrefix,
                    dynamicConstraints: dynamicConstraints,
                    maximumResponseTokens: responseTokens,
                    timeoutSeconds: 8
                )
            ).text
            if TranscriptRewriteValidator.isAcceptable(
                candidate: candidate,
                original: text
            ), layout.preservesCommands(in: candidate) {
                return finalized(candidate, for: intent)
            }

            let conservativeConstraints = """
            \(dynamicConstraints)

            Make a conservative second pass by editing the source in place.
            Keep every original clause and keep each required meaning marker in its original clause and grammatical role.
            Do not change a personal task into a command or a statement into a message addressed to someone.
            """
            let conservativeCandidate = try await rewriter.rewrite(
                LocalTranscriptRewriteRequest(
                    text: text,
                    sessionInstructions: intent.instructions(for: target),
                    promptPrefix: Self.rewritePromptPrefix,
                    dynamicConstraints: conservativeConstraints,
                    maximumResponseTokens: responseTokens,
                    timeoutSeconds: 8
                )
            ).text
            guard TranscriptRewriteValidator.isAcceptable(
                candidate: conservativeCandidate,
                original: text
            ), layout.preservesCommands(in: conservativeCandidate) else {
                return fallback(text, for: intent)
            }
            return finalized(conservativeCandidate, for: intent)
        } catch {
            FileHandle.standardError.write(
                Data("local formatting unavailable; used safe cleanup: \(error)\n".utf8)
            )
            return fallback(text, for: intent)
        }
    }

    private static let rewritePromptPrefix =
        "Rewrite this dictated message without answering it. "
        + "Return only the rewritten message:\n\n"

    private func finalized(_ text: String, for intent: TranscriptRewriteIntent) -> String {
        switch intent {
        case .formatted:
            return text
        case .professional:
            return TranscriptProcessor.professionalize(text)
        case .aiCommunication:
            return TranscriptProcessor.structureForAI(text)
        }
    }

    private func fallback(_ text: String, for intent: TranscriptRewriteIntent) -> String {
        finalized(TranscriptProcessor.polish(text), for: intent)
    }
}

private enum TranscriptRewriteIntent: Equatable {
    case formatted
    case professional
    case aiCommunication

    init?(profile: TranscriptFormattingProfile) {
        switch profile {
        case .casual:
            return nil
        case .formatted:
            self = .formatted
        case .professional:
            self = .professional
        case .aiCommunication:
            self = .aiCommunication
        }
    }

    func instructions(for target: TranscriptTarget) -> String {
        let application = target.applicationName ?? "the current application"
        let shared = """
        You edit voice dictation before it is inserted into \(application).
        Preserve every fact, request, constraint, example, uncertainty, negation, number, name, and technical term.
        Preserve who is speaking, who must act, and who receives each action.
        Preserve modality and speech act: a personal task, observation, question, or draft message must remain that same kind of statement.
        Never turn a statement about someone into text addressed to that person.
        Never answer the message. Never add facts, recommendations, claims, or intent.
        Remove speech fillers, false starts, and accidental repetition only when meaning is unchanged.
        Resolve explicit spoken self-corrections in place. For example, "Friday—wait, no, Monday" means Monday, "Blumira—I meant Valyou" means Valyou, and "scratch that" discards the abandoned clause.
        Do not preserve correction phrases in the final text, and do not treat an ordinary semantic "no" as a correction.
        Return only the rewritten text with no preamble, label, quotation, or code fence.
        """

        switch self {
        case .formatted:
            return """
            \(shared)
            Keep the speaker's natural tone and vocabulary.
            Fix grammar, capitalization, punctuation, sentence boundaries, and run-on thoughts.
            Use short paragraphs. Use bullets only when the speaker clearly gives a list or several separate requirements.
            Prefer clarity and scanability over formality.
            """
        case .professional:
            return """
            \(shared)
            Produce polished professional communication that is concise, confident, and precise.
            Remove conversational throat-clearing such as "okay" and "so."
            Improve awkward wording and organization when it makes the intended meaning clearer.
            Preserve the speaker's level of certainty and do not inflate claims.
            Preserve qualifiers such as "I think," "probably," and "maybe" when they express real uncertainty.
            Use coherent paragraphs and purposeful bullets when appropriate.
            Sound like an excellent human editor, not corporate boilerplate.
            Do more than add punctuation, but keep edits conservative enough that every sentence still has the speaker's intended meaning.
            """
        case .aiCommunication:
            return """
            \(shared)
            Structure the message as excellent input for an AI agent.
            Preserve the speaker's actual request shape; do not turn every thought into a task brief.
            Use paragraphs for connected reasoning, explanation, questions, and ordinary prose.
            Use bullets only for genuinely parallel items such as requirements, constraints, examples, or options.
            Use numbered steps only for a true sequence where order matters.
            For a complex execution request, make the objective, relevant context, requirements, constraints, and requested result easy to find, using lightweight headings only when they materially improve scanability.
            Keep a short or simple request as a short or simple request.
            Keep prohibitions and non-negotiable constraints visibly distinct from optional ideas.
            Preserve open questions and ambiguity instead of deciding them for the speaker.
            Never invent a missing requirement, priority, deadline, deliverable, or decision.
            """
        }
    }
}

actor FoundationModelTranscriptRewriter: LocalTranscriptRewriting {
    enum RewriterError: Error {
        case unavailable
        case timedOut
    }

    enum PreparationMode: Equatable, Sendable {
        case legacyDynamicInstructions
        case stablePromptConstraints
    }

    static let defaultPreparationMode: PreparationMode =
        .legacyDynamicInstructions

    struct RecordedRun: Sendable {
        let preparedSessionHit: Bool
    }

    private struct PreparedSessionKey: Hashable {
        let instructions: String
        let promptPrefix: String
    }

    private var preparedSessions: [PreparedSessionKey: Any] = [:]
    private var recordedRuns: [RecordedRun] = []
    private let maximumPreparedSessions = 4
    private let preparationMode: PreparationMode
    private let recordsRuns: Bool

    init(
        preparationMode: PreparationMode =
            FoundationModelTranscriptRewriter.defaultPreparationMode,
        recordsRuns: Bool = false
    ) {
        self.preparationMode = preparationMode
        self.recordsRuns = recordsRuns
    }

    func prewarm(
        sessionInstructions: String,
        promptPrefix: String
    ) async {
#if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return }
        guard case .available = SystemLanguageModel.default.availability else { return }
        let key = PreparedSessionKey(
            instructions: sessionInstructions,
            promptPrefix: preparationMode == .stablePromptConstraints
                ? promptPrefix
                : ""
        )
        guard preparedSessions[key] == nil else { return }
        if preparedSessions.count >= maximumPreparedSessions,
           let oldestKey = preparedSessions.keys.first
        {
            preparedSessions.removeValue(forKey: oldestKey)
        }
        let session = LanguageModelSession(instructions: sessionInstructions)
        if preparationMode == .stablePromptConstraints {
            session.prewarm(promptPrefix: Prompt(promptPrefix))
        } else {
            session.prewarm()
        }
        preparedSessions[key] = session
#endif
    }

    func rewrite(
        _ request: LocalTranscriptRewriteRequest
    ) async throws -> LocalTranscriptRewriteResult {
#if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw RewriterError.unavailable
        }
        guard case .available = SystemLanguageModel.default.availability else {
            throw RewriterError.unavailable
        }

        let instructions: String
        let prompt: String
        let promptPrefixKey: String
        switch preparationMode {
        case .legacyDynamicInstructions:
            instructions = request.sessionInstructions
                + request.dynamicConstraints
            prompt = request.promptPrefix + request.text
            promptPrefixKey = ""
        case .stablePromptConstraints:
            instructions = request.sessionInstructions
            prompt = request.promptPrefix
                + request.dynamicConstraints
                + "\n\n"
                + request.text
            promptPrefixKey = request.promptPrefix
        }
        let key = PreparedSessionKey(
            instructions: instructions,
            promptPrefix: promptPrefixKey
        )
        let preparedSession = preparedSessions.removeValue(forKey: key)
        let preparedSessionHit = preparedSession != nil
        let session =
            preparedSession as? LanguageModelSession
            ?? LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(
            sampling: .greedy,
            temperature: 0,
            maximumResponseTokens: request.maximumResponseTokens
        )
        let text = try await Self.respond(
            session: session,
            prompt: prompt,
            options: options,
            timeoutSeconds: request.timeoutSeconds
        )
        if recordsRuns {
            recordedRuns.append(RecordedRun(
                preparedSessionHit: preparedSessionHit
            ))
        }
        Task {
            await self.prewarm(
                sessionInstructions: instructions,
                promptPrefix: promptPrefixKey
            )
        }
        return LocalTranscriptRewriteResult(
            text: text
        )
#else
        throw RewriterError.unavailable
#endif
    }

    func runs() -> [RecordedRun] {
        recordedRuns
    }

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func respond(
        session: LanguageModelSession,
        prompt: String,
        options: GenerationOptions,
        timeoutSeconds: UInt64
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let response = try await session.respond(to: prompt, options: options)
                return cleanModelOutput(response.content)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw RewriterError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw RewriterError.timedOut
            }
            return first
        }
    }

    private static func cleanModelOutput(_ output: String) -> String {
        var result = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```"), result.hasSuffix("```") {
            result = result
                .replacingOccurrences(
                    of: #"^```(?:text|markdown)?\s*"#,
                    with: "",
                    options: .regularExpression
                )
                .replacingOccurrences(
                    of: #"\s*```$"#,
                    with: "",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
#endif
}
