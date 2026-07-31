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
    case wouldEmptySentence = "would_empty_sentence"
    case unsafeDeletionBoundary = "unsafe_deletion_boundary"
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
/// `command correction, delete <target phrase>`.
/// Whisper may punctuate between `correction` and the edit verb. Every rejected
/// command returns the input unchanged so an ambiguous edit cannot hide text.
public enum SpokenReplacementCommandEngine {
    private enum Operation {
        case replace
        case insert
        case delete

        var delimiterPattern: String? {
            switch self {
            case .replace:
                return #"(?i)(?<![\p{L}\p{N}'’-])with(?![\p{L}\p{N}'’-])"#
            case .insert:
                return #"(?i)(?<![\p{L}\p{N}'’-])after(?![\p{L}\p{N}'’-])"#
            case .delete:
                return nil
            }
        }
    }

    private static let namespacePattern =
        #"(?i)(?<![\p{L}\p{N}'’-])command\s+correction(?![\p{L}\p{N}'’-])"#
    private static let replacementCommandPattern =
        #"(?i)(?<![\p{L}\p{N}'’-])command\s+correction\s*(?:[,.:;—–-]\s*)?replace(?![\p{L}\p{N}'’-])"#
    private static let insertionCommandPattern =
        #"(?i)(?<![\p{L}\p{N}'’-])command\s+correction\s*(?:[,.:;—–-]\s*)?insert(?![\p{L}\p{N}'’-])"#
    private static let deletionCommandPattern =
        #"(?i)(?<![\p{L}\p{N}'’-])command\s+correction\s*(?:[,.:;—–-]\s*)?delete(?![\p{L}\p{N}'’-])"#
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
        let deletionCommandRanges = ranges(
            matching: deletionCommandPattern,
            in: text
        )
        let commandRanges =
            replacementCommandRanges
            + insertionCommandRanges
            + deletionCommandRanges
        guard
            commandRanges.count == 1,
            commandRanges[0].lowerBound == namespaceRanges[0].lowerBound
        else {
            return rejected(.malformedCommand, preserving: text)
        }
        let commandRange = commandRanges[0]
        let operation: Operation
        if !replacementCommandRanges.isEmpty {
            operation = .replace
        } else if !insertionCommandRanges.isEmpty {
            operation = .insert
        } else {
            operation = .delete
        }

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
        guard !payload.isEmpty else {
            return rejected(.missingPayload, preserving: text)
        }
        guard !containsSentenceBoundary(in: payload) else {
            return rejected(.nonTerminal, preserving: text)
        }

        let firstPhrase: String
        let secondPhrase: String?
        if let delimiterPattern = operation.delimiterPattern {
            let delimiterRanges = ranges(
                matching: delimiterPattern,
                in: payload
            )
            guard !delimiterRanges.isEmpty else {
                return rejected(.missingPayload, preserving: text)
            }
            guard delimiterRanges.count == 1 else {
                return rejected(.ambiguousDelimiter, preserving: text)
            }
            let delimiter = delimiterRanges[0]
            firstPhrase = String(payload[..<delimiter.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            secondPhrase = String(payload[delimiter.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !firstPhrase.isEmpty, secondPhrase?.isEmpty == false else {
                return rejected(.missingPayload, preserving: text)
            }
        } else {
            firstPhrase = payload
            secondPhrase = nil
            guard !beginsWithReservedOperation(firstPhrase) else {
                return rejected(.malformedCommand, preserving: text)
            }
        }
        guard firstPhrase.count <= 80, matchesEntirePhrase(firstPhrase) else {
            return rejected(.payloadTooLarge, preserving: text)
        }
        if let secondPhrase {
            guard
                secondPhrase.count <= 80,
                matchesEntirePhrase(secondPhrase)
            else {
                return rejected(.payloadTooLarge, preserving: text)
            }
        }

        let targetPhrase: String
        let insertedOrReplacementPhrase: String?
        switch operation {
        case .replace:
            targetPhrase = firstPhrase
            insertedOrReplacementPhrase = secondPhrase
            guard targetPhrase != secondPhrase else {
                return rejected(.noChange, preserving: text)
            }
        case .insert:
            insertedOrReplacementPhrase = firstPhrase
            targetPhrase = secondPhrase ?? ""
        case .delete:
            targetPhrase = firstPhrase
            insertedOrReplacementPhrase = nil
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
            guard let insertedOrReplacementPhrase else {
                return rejected(.missingPayload, preserving: text)
            }
            edited.replaceSubrange(
                targetRanges[0],
                with: insertedOrReplacementPhrase
            )
        case .insert:
            guard let insertedOrReplacementPhrase else {
                return rejected(.missingPayload, preserving: text)
            }
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
        case .delete:
            guard !wouldEmptySentence(
                byDeleting: targetRanges[0],
                in: body
            ) else {
                return rejected(.wouldEmptySentence, preserving: text)
            }
            guard let deletionRange = safeDeletionRange(
                for: targetRanges[0],
                in: body
            ) else {
                return rejected(.unsafeDeletionBoundary, preserving: text)
            }
            edited.removeSubrange(deletionRange)
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

    private static func safeDeletionRange(
        for target: Range<String.Index>,
        in text: String
    ) -> Range<String.Index>? {
        guard target.lowerBound > text.startIndex else { return nil }
        let precedingIndex = text.index(before: target.lowerBound)
        guard isHorizontalWhitespace(text[precedingIndex]) else {
            return nil
        }
        var precedingBoundary = precedingIndex
        while precedingBoundary > text.startIndex {
            let candidate = text.index(before: precedingBoundary)
            guard isHorizontalWhitespace(text[candidate]) else { break }
            precedingBoundary = candidate
        }
        let previousIndex = precedingBoundary > text.startIndex
            ? text.index(before: precedingBoundary)
            : text.startIndex
        guard isLexicalCharacter(text[previousIndex]) else {
            return nil
        }
        guard target.upperBound < text.endIndex else { return nil }
        let following = text[target.upperBound]
        if isHorizontalWhitespace(following) {
            var upperBound = target.upperBound
            while upperBound < text.endIndex,
                  isHorizontalWhitespace(text[upperBound])
            {
                upperBound = text.index(after: upperBound)
            }
            guard upperBound < text.endIndex,
                  isLexicalCharacter(text[upperBound])
            else {
                return nil
            }
            return target.lowerBound..<upperBound
        }
        if ".!?".contains(following) {
            return precedingBoundary..<target.upperBound
        }
        return nil
    }

    private static func wouldEmptySentence(
        byDeleting target: Range<String.Index>,
        in text: String
    ) -> Bool {
        let boundaries = ranges(
            matching: #"(?<!\p{N})\.(?!\p{N})|[!?]"#,
            in: text
        )
        let sentenceStart = boundaries.last {
            $0.upperBound <= target.lowerBound
        }?.upperBound ?? text.startIndex
        let sentenceEnd = boundaries.first {
            $0.lowerBound >= target.upperBound
        }?.upperBound ?? text.endIndex
        let sentenceRange = sentenceStart..<sentenceEnd
        var sentence = String(text[sentenceRange])
        let lowerOffset = text.distance(
            from: sentenceRange.lowerBound,
            to: target.lowerBound
        )
        let upperOffset = text.distance(
            from: sentenceRange.lowerBound,
            to: target.upperBound
        )
        let lower = sentence.index(sentence.startIndex, offsetBy: lowerOffset)
        let upper = sentence.index(sentence.startIndex, offsetBy: upperOffset)
        sentence.removeSubrange(lower..<upper)
        return !sentence.unicodeScalars.contains {
            CharacterSet.alphanumerics.contains($0)
        }
    }

    private static func isHorizontalWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

    private static func isLexicalCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            CharacterSet.alphanumerics.contains($0)
        }
    }

    private static func beginsWithReservedOperation(_ phrase: String) -> Bool {
        let firstWord = phrase
            .split(whereSeparator: \.isWhitespace)
            .first?
            .lowercased()
        return firstWord == "replace"
            || firstWord == "insert"
            || firstWord == "delete"
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
