import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import WordhandCore

protocol LocalTranscriptRewriting: Sendable {
    func prewarm(instructions: String) async
    func rewrite(
        _ text: String,
        instructions: String,
        maximumResponseTokens: Int,
        timeoutSeconds: UInt64
    ) async throws -> String
}

extension LocalTranscriptRewriting {
    func prewarm(instructions: String) async {}
}

final class AppAwareTranscriptProcessor: TranscriptProcessing, @unchecked Sendable {
    private let dictionaryProcessor: MutableTranscriptProcessor
    private let rewriter: any LocalTranscriptRewriting
    private let lock = NSLock()
    private var profile: TranscriptFormattingProfile
    private var performanceMode: ProcessingPerformanceMode

    init(
        dictionaryProcessor: MutableTranscriptProcessor,
        profile: TranscriptFormattingProfile,
        performanceMode: ProcessingPerformanceMode = .adaptive,
        rewriter: any LocalTranscriptRewriting = FoundationModelTranscriptRewriter()
    ) {
        self.dictionaryProcessor = dictionaryProcessor
        self.profile = profile
        self.performanceMode = performanceMode
        self.rewriter = rewriter
    }

    func update(
        profile: TranscriptFormattingProfile,
        performanceMode: ProcessingPerformanceMode? = nil
    ) {
        lock.withLock {
            self.profile = profile
            if let performanceMode {
                self.performanceMode = performanceMode
            }
        }
    }

    func prepare(target: TranscriptTarget) async {
        let configuration = lock.withLock { (profile, performanceMode) }
        guard configuration.1 == .maximum else { return }
        guard let intent = TranscriptRewriteIntent(profile: configuration.0) else {
            return
        }
        await rewriter.prewarm(instructions: intent.instructions(for: target))
    }

    func process(_ text: String, target: TranscriptTarget) async -> String {
        let cleaned = await dictionaryProcessor.process(text, target: target)
        let selectedProfile = lock.withLock { profile }

        switch selectedProfile {
        case .casual:
            return TranscriptProcessor.polish(cleaned)
        case .formatted:
            return await rewrite(cleaned, intent: .formatted, target: target)
        case .professional:
            return await rewrite(cleaned, intent: .professional, target: target)
        case .aiCommunication:
            return await rewrite(cleaned, intent: .aiCommunication, target: target)
        }
    }

    private func rewrite(
        _ text: String,
        intent: TranscriptRewriteIntent,
        target: TranscriptTarget
    ) async -> String {
        guard !text.isEmpty else { return text }
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        let responseTokens = min(768, max(128, wordCount * 3))
        let meaningMarkers = TranscriptRewriteValidator.requiredMeaningMarkers(in: text)
            .sorted()
            .joined(separator: ", ")
        var instructions = intent.instructions(for: target)
        if !meaningMarkers.isEmpty {
            instructions += """

            The source contains these meaning markers: \(meaningMarkers).
            Retain every one in the rewrite. They encode speaker perspective, modality, or requested action.
            """
        }

        do {
            let candidate = try await rewriter.rewrite(
                text,
                instructions: instructions,
                maximumResponseTokens: responseTokens,
                timeoutSeconds: 8
            )
            if TranscriptRewriteValidator.isAcceptable(
                candidate: candidate,
                original: text
            ) {
                return finalized(candidate, for: intent)
            }

            let conservativeInstructions = """
            \(instructions)

            Make a conservative second pass by editing the source in place.
            Keep every original clause and keep each required meaning marker in its original clause and grammatical role.
            Do not change a personal task into a command or a statement into a message addressed to someone.
            """
            let conservativeCandidate = try await rewriter.rewrite(
                text,
                instructions: conservativeInstructions,
                maximumResponseTokens: responseTokens,
                timeoutSeconds: 8
            )
            guard TranscriptRewriteValidator.isAcceptable(
                candidate: conservativeCandidate,
                original: text
            ) else {
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
            Make the goal, context, requirements, constraints, examples, and requested output easy to identify.
            Use short sections or bullets when they help the agent execute correctly.
            When the source contains three or more separate actions or requirements, use a concise lead sentence followed by bullets instead of one flat paragraph.
            Keep prohibitions and non-negotiable constraints visibly distinct from optional ideas.
            Preserve open questions and ambiguity instead of deciding them for the speaker.
            Do not add headings mechanically when a short message is already clear.
            """
        }
    }
}

actor FoundationModelTranscriptRewriter: LocalTranscriptRewriting {
    enum RewriterError: Error {
        case unavailable
        case timedOut
    }

    private var preparedSessions: [String: Any] = [:]
    private let maximumPreparedSessions = 4

    func prewarm(instructions: String) async {
#if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return }
        guard case .available = SystemLanguageModel.default.availability else { return }
        guard preparedSessions[instructions] == nil else { return }
        if preparedSessions.count >= maximumPreparedSessions,
           let oldestKey = preparedSessions.keys.first
        {
            preparedSessions.removeValue(forKey: oldestKey)
        }
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
        preparedSessions[instructions] = session
#endif
    }

    func rewrite(
        _ text: String,
        instructions: String,
        maximumResponseTokens: Int,
        timeoutSeconds: UInt64
    ) async throws -> String {
#if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw RewriterError.unavailable
        }
        guard case .available = SystemLanguageModel.default.availability else {
            throw RewriterError.unavailable
        }

        let prompt = """
        Rewrite this dictated message without answering it. Return only the rewritten message:

        \(text)
        """
        let session =
            preparedSessions.removeValue(forKey: instructions) as? LanguageModelSession
            ?? LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(
            sampling: .greedy,
            temperature: 0,
            maximumResponseTokens: maximumResponseTokens
        )
        let result = try await Self.respond(
            session: session,
            prompt: prompt,
            options: options,
            timeoutSeconds: timeoutSeconds
        )
        Task { await self.prewarm(instructions: instructions) }
        return result
#else
        throw RewriterError.unavailable
#endif
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
