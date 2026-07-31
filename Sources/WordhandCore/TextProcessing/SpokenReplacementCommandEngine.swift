import Foundation

public enum SpokenReplacementCommandRejection: String, Equatable, Sendable {
    case multipleCommands = "multiple_commands"
    case malformedCommand = "malformed_command"
    case missingBody = "missing_body"
    case missingPayload = "missing_payload"
    case ambiguousDelimiter = "ambiguous_delimiter"
    case nonStandalone = "non_standalone"
    case nonTerminal = "non_terminal"
    case questionCommand = "question_command"
    case payloadTooLarge = "payload_too_large"
    case noChange = "no_change"
    case targetMissing = "target_missing"
    case targetRepeated = "target_repeated"
}

public enum SpokenReplacementCommandOutcome: Equatable, Sendable {
    case noCommand
    case applied
    case rejected(SpokenReplacementCommandRejection)
}

public struct SpokenReplacementCommandResult: Equatable, Sendable {
    public let text: String
    public let outcome: SpokenReplacementCommandOutcome

    public init(
        text: String,
        outcome: SpokenReplacementCommandOutcome
    ) {
        self.text = text
        self.outcome = outcome
    }
}

/// Applies one exact, terminal edit command to the current transcript.
///
/// The reserved spoken forms are:
/// `command correction, replace <old phrase> with <new phrase>`.
/// `command correction, insert <new phrase> after <anchor phrase>`.
/// Whisper may punctuate between `correction` and the edit verb. Every rejected
/// command returns the input unchanged so an ambiguous edit cannot hide text.
public enum SpokenReplacementCommandEngine {
    private enum Operation {
        case replace
        case insert

        var delimiterPattern: String {
            switch self {
            case .replace:
                return #"(?i)(?<![\p{L}\p{N}'’-])with(?![\p{L}\p{N}'’-])"#
            case .insert:
                return #"(?i)(?<![\p{L}\p{N}'’-])after(?![\p{L}\p{N}'’-])"#
            }
        }
    }

    private static let namespacePattern =
        #"(?i)(?<![\p{L}\p{N}'’-])command\s+correction(?![\p{L}\p{N}'’-])"#
    private static let replacementCommandPattern =
        #"(?i)(?<![\p{L}\p{N}'’-])command\s+correction\s*(?:[,.:;—–-]\s*)?replace(?![\p{L}\p{N}'’-])"#
    private static let insertionCommandPattern =
        #"(?i)(?<![\p{L}\p{N}'’-])command\s+correction\s*(?:[,.:;—–-]\s*)?insert(?![\p{L}\p{N}'’-])"#
    private static let phrasePattern =
        #"^[\p{L}\p{N}]+(?:['’.-][\p{L}\p{N}]+)*(?:\s+[\p{L}\p{N}]+(?:['’.-][\p{L}\p{N}]+)*){0,7}$"#

    public static func apply(to text: String) -> SpokenReplacementCommandResult {
        let namespaceRanges = ranges(
            matching: namespacePattern,
            in: text
        )
        guard !namespaceRanges.isEmpty else {
            return SpokenReplacementCommandResult(
                text: text,
                outcome: .noCommand
            )
        }
        guard namespaceRanges.count == 1 else {
            return rejected(.multipleCommands, preserving: text)
        }

        let replacementCommandRanges = ranges(
            matching: replacementCommandPattern,
            in: text
        )
        let insertionCommandRanges = ranges(
            matching: insertionCommandPattern,
            in: text
        )
        let commandRanges =
            replacementCommandRanges + insertionCommandRanges
        guard
            commandRanges.count == 1,
            commandRanges[0].lowerBound == namespaceRanges[0].lowerBound
        else {
            return rejected(.malformedCommand, preserving: text)
        }
        let commandRange = commandRanges[0]
        let operation: Operation = insertionCommandRanges.isEmpty
            ? .replace
            : .insert

        let prefix = String(text[..<commandRange.lowerBound])
        let body = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return rejected(.missingBody, preserving: text)
        }
        guard body.last.map({ ".!?".contains($0) }) == true else {
            return rejected(.nonStandalone, preserving: text)
        }

        var payload = String(text[commandRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else {
            return rejected(.missingPayload, preserving: text)
        }
        if payload.last == "?" {
            return rejected(.questionCommand, preserving: text)
        }
        if let last = payload.last, ".!".contains(last) {
            payload.removeLast()
            payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !containsSentenceBoundary(in: payload) else {
            return rejected(.nonTerminal, preserving: text)
        }

        let delimiterRanges = ranges(
            matching: operation.delimiterPattern,
            in: payload
        )
        guard !delimiterRanges.isEmpty else {
            return rejected(.missingPayload, preserving: text)
        }
        guard delimiterRanges.count == 1 else {
            return rejected(.ambiguousDelimiter, preserving: text)
        }

        let delimiter = delimiterRanges[0]
        let firstPhrase = String(payload[..<delimiter.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let secondPhrase = String(payload[delimiter.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !firstPhrase.isEmpty, !secondPhrase.isEmpty else {
            return rejected(.missingPayload, preserving: text)
        }
        guard
            firstPhrase.count <= 80,
            secondPhrase.count <= 80,
            matchesEntirePhrase(firstPhrase),
            matchesEntirePhrase(secondPhrase)
        else {
            return rejected(.payloadTooLarge, preserving: text)
        }

        let targetPhrase: String
        let insertedOrReplacementPhrase: String
        switch operation {
        case .replace:
            targetPhrase = firstPhrase
            insertedOrReplacementPhrase = secondPhrase
            guard targetPhrase != insertedOrReplacementPhrase else {
                return rejected(.noChange, preserving: text)
            }
        case .insert:
            insertedOrReplacementPhrase = firstPhrase
            targetPhrase = secondPhrase
        }
        let targetRanges = exactPhraseRanges(
            targetPhrase,
            in: body
        )
        guard !targetRanges.isEmpty else {
            return rejected(.targetMissing, preserving: text)
        }
        guard targetRanges.count == 1 else {
            return rejected(.targetRepeated, preserving: text)
        }

        var edited = body
        switch operation {
        case .replace:
            edited.replaceSubrange(
                targetRanges[0],
                with: insertedOrReplacementPhrase
            )
        case .insert:
            guard !hasImmediatePhrase(
                insertedOrReplacementPhrase,
                after: targetRanges[0],
                in: body
            ) else {
                return rejected(.noChange, preserving: text)
            }
            edited.insert(
                contentsOf: " \(insertedOrReplacementPhrase)",
                at: targetRanges[0].upperBound
            )
        }
        return SpokenReplacementCommandResult(
            text: edited,
            outcome: .applied
        )
    }

    private static func rejected(
        _ reason: SpokenReplacementCommandRejection,
        preserving text: String
    ) -> SpokenReplacementCommandResult {
        SpokenReplacementCommandResult(
            text: text,
            outcome: .rejected(reason)
        )
    }

    private static func matchesEntirePhrase(_ text: String) -> Bool {
        guard let expression = try? NSRegularExpression(
            pattern: phrasePattern
        ) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.firstMatch(in: text, range: range)?.range == range
    }

    private static func containsSentenceBoundary(in text: String) -> Bool {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?<!\p{N})\.(?!\p{N})|[!?;]"#
        ) else {
            return true
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.firstMatch(in: text, range: range) != nil
    }

    private static func exactPhraseRanges(
        _ phrase: String,
        in text: String
    ) -> [Range<String.Index>] {
        let words = phrase.split(whereSeparator: \.isWhitespace)
        let escaped = words
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: #"\s+"#)
        let pattern =
            #"(?=(?<target>(?<![\p{L}\p{N}'’-])"#
            + #"(?<![\p{L}\p{N}]\.)"#
            + escaped
            + #"(?![\p{L}\p{N}'’-])"#
            + #"(?!\.[\p{L}\p{N}])"#
            + #"))"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return []
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: fullRange).compactMap {
            Range($0.range(withName: "target"), in: text)
        }
    }

    private static func hasImmediatePhrase(
        _ phrase: String,
        after target: Range<String.Index>,
        in text: String
    ) -> Bool {
        let words = phrase.split(whereSeparator: \.isWhitespace)
        let escaped = words
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: #"\s+"#)
        let pattern =
            #"^[ \t]*(?:[,;:—–-][ \t]*)?"#
            + escaped
            + #"(?![\p{L}\p{N}'’-])"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return false
        }
        let suffix = String(text[target.upperBound...])
        let fullRange = NSRange(
            suffix.startIndex..<suffix.endIndex,
            in: suffix
        )
        return expression.firstMatch(in: suffix, range: fullRange) != nil
    }

    private static func ranges(
        matching pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> [Range<String.Index>] {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: options
        ) else {
            return []
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: fullRange).compactMap {
            Range($0.range, in: text)
        }
    }
}
