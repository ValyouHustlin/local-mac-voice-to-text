import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import WordhandCore

final class AppAwareTranscriptProcessor: TranscriptProcessing, @unchecked Sendable {
    private let dictionaryProcessor: MutableTranscriptProcessor
    private let lock = NSLock()
    private var profile: TranscriptFormattingProfile

    init(
        dictionaryProcessor: MutableTranscriptProcessor,
        profile: TranscriptFormattingProfile
    ) {
        self.dictionaryProcessor = dictionaryProcessor
        self.profile = profile
    }

    func update(profile: TranscriptFormattingProfile) {
        lock.withLock {
            self.profile = profile
        }
    }

    func process(_ text: String, target: TranscriptTarget) async -> String {
        let cleaned = await dictionaryProcessor.process(text, target: target)
        let resolved = lock.withLock { profile }.resolved(for: target)

        switch resolved {
        case .verbatim:
            return cleaned
        case .polished, .automatic:
            return TranscriptProcessor.polish(cleaned)
        case .aiPrompt:
            return await rewriteForAI(cleaned, target: target)
        }
    }

    private func rewriteForAI(_ text: String, target: TranscriptTarget) async -> String {
        guard !text.isEmpty else { return text }
#if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            return TranscriptProcessor.polish(text)
        }
        guard case .available = SystemLanguageModel.default.availability else {
            return TranscriptProcessor.polish(text)
        }

        let application = target.applicationName ?? "an AI coding application"
        let instructions = """
        You edit voice dictation into excellent input for an AI coding assistant.
        The user is dictating into \(application).
        Preserve every request, constraint, example, uncertainty, and technical term.
        Do not answer the request and do not add facts or recommendations.
        Remove only speech fillers and accidental repetition.
        Fix capitalization, punctuation, and run-on sentences.
        Use short paragraphs and bullets when they make multiple requirements easier to scan.
        Return only the rewritten dictation with no preamble, label, quote, or code fence.
        """
        let prompt = """
        Rewrite this dictated message without answering it. Return only the rewritten message:

        \(text)
        """
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        let responseTokens = min(384, max(96, wordCount * 2))

        do {
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(
                sampling: .greedy,
                temperature: 0,
                maximumResponseTokens: responseTokens
            )
            let candidate = try await Self.respond(
                session: session,
                prompt: prompt,
                options: options,
                timeoutSeconds: 4
            )
            guard TranscriptRewriteValidator.isAcceptable(
                candidate: candidate,
                original: text
            ) else {
                return TranscriptProcessor.polish(text)
            }
            return candidate
        } catch {
            FileHandle.standardError.write(
                Data("local formatting unavailable; used safe cleanup: \(error)\n".utf8)
            )
            return TranscriptProcessor.polish(text)
        }
#else
        return TranscriptProcessor.polish(text)
#endif
    }

#if canImport(FoundationModels)
    private enum FormattingError: Error {
        case timedOut
    }

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
                throw FormattingError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw FormattingError.timedOut
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
