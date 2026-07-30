import Testing
@testable import WordhandCore

@Suite
struct SpokenLayoutCommandEngineTests {
    @Test
    func rendersStandaloneLineAndParagraphCommandsExactly() {
        let plan = SpokenLayoutCommandEngine.protect(
            "First line. Command new line. Second line. "
                + "Command new paragraph. Final paragraph."
        )

        #expect(plan.commandCount == 2)
        #expect(!plan.protectedText.localizedCaseInsensitiveContains("command new line"))
        #expect(!plan.protectedText.localizedCaseInsensitiveContains(
            "command new paragraph"
        ))
        #expect(plan.preservesCommands(in: plan.protectedText))
        #expect(
            plan.render(plan.protectedText)
                == "First line.\nSecond line.\n\nFinal paragraph."
        )
    }

    @Test
    func rendersObservedCommaDelimitedWhisperCommandsWithoutSeparatorCommas() {
        let plan = SpokenLayoutCommandEngine.protect(
            "First thought, command new line, second thought, "
                + "command new paragraph, final thought."
        )

        #expect(plan.commandCount == 2)
        #expect(
            plan.render(plan.protectedText)
                == "First thought\nSecond thought\n\nFinal thought."
        )
    }

    @Test
    func refusesSemanticOrStructurallyAmbiguousLayoutLanguage() {
        let examples = [
            "Start a new paragraph about pricing.",
            "The label says new paragraph.",
            "New paragraph. This phrase begins the dictation.",
            "He said “New paragraph.” Then he continued.",
            "He wrote, new paragraph, in the transcript.",
            "“First thought. Command new paragraph. Second thought.”",
            ". Command new line. Content follows.",
            "First thought. Command new line. ”",
            "We need a new line item.",
            "This is the new line. It matters.",
            "First sentence. New paragraph?",
            "First sentence. New paragraph.",
        ]

        for input in examples {
            let plan = SpokenLayoutCommandEngine.protect(input)
            #expect(plan.commandCount == 0)
            #expect(plan.protectedText == input)
            #expect(plan.render(input) == input)
        }
    }

    @Test
    func requiresEveryProtectedCommandExactlyOnceAndInOrder() {
        let plan = SpokenLayoutCommandEngine.protect(
            "One. Command new line. Two. Command new paragraph. Three."
        )
        let tokens = plan.protectedText
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { $0.hasPrefix("WORDHAND_LAYOUT_") }
        #expect(tokens.count == 2)
        #expect(plan.preservesCommands(in: plan.protectedText))
        #expect(!plan.preservesCommands(in: "One. \(tokens[0]) Two. Three."))
        #expect(!plan.preservesCommands(
            in: "One. \(tokens[1]) Two. \(tokens[0]) Three."
        ))
        #expect(!plan.preservesCommands(
            in: "One. \(tokens[0]) \(tokens[0]) Two. \(tokens[1]) Three."
        ))
        #expect(!plan.preservesCommands(
            in: "One. \(tokens[0]) Two. \(tokens[1]) Three. "
                + "wordhand_layout_injected"
        ))
        let malformedExtras = [
            "WORDHAND_LAYOUT_",
            "wordhand_layout-injected",
            "\(tokens[0])-evil",
        ]
        for extra in malformedExtras {
            let candidate =
                "One. \(tokens[0]) Two. \(tokens[1]) Three. \(extra)"
            #expect(!plan.preservesCommands(in: candidate))
            let rendered = plan.render(candidate)
            #expect(rendered == "One.\nTwo.\n\nThree.")
            #expect(!rendered.localizedCaseInsensitiveContains(extra))
        }
        #expect(!plan.preservesCommands(
            in: "One. Two. \(tokens[0]) \(tokens[1]) Three."
        ))
        #expect(
            plan.render("One. Two. Three.")
                == "One.\nTwo.\n\nThree."
        )
    }

    @Test
    func anchorsMustRemainImmediatelyBesideTheProtectedBoundary() throws {
        let plan = SpokenLayoutCommandEngine.protect(
            "Zero one two three four. Command new line. Five six seven eight."
        )
        let token = try #require(
            plan.protectedText
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .first(where: { $0.hasPrefix("WORDHAND_LAYOUT_") })
        )

        #expect(!plan.preservesCommands(
            in: "One two three four zero. \(token) Five six seven eight."
        ))
        #expect(!plan.preservesCommands(
            in: "Zero one two three four. \(token) Six seven eight five."
        ))
        #expect(
            plan.render(
                "One two three four zero. \(token) Five six seven eight."
            ) == "Zero one two three four.\nFive six seven eight."
        )
    }

    @Test
    func directProcessorAppliesLayoutAfterDeterministicCleanup() async {
        let processor = TranscriptProcessor(formattingProfile: .casual)

        let output = await processor.process(
            "um First thought. Command new paragraph. Second thought"
        )

        #expect(output == "First thought.\n\nSecond thought.")
    }

    @Test
    func noCommandLeavesFormatterWhitespaceAndCapitalizationUntouched() {
        let candidate = """
        Heading

          - indented child
            continuation
        """
        let plan = SpokenLayoutCommandEngine.protect("ordinary source")

        #expect(plan.render(candidate) == candidate)
    }

    @Test
    func nonceSkipsEveryOccupiedPrefixWithoutABoundedFallback() {
        let occupied = (1...1_100).reduce("Prefix.") {
            partial, length in
            partial + " WORDHAND_LAYOUT_"
                + String(repeating: "0", count: length)
                + "_0"
        }
        let input =
            occupied
            + " Before. Command new line. After."
        let plan = SpokenLayoutCommandEngine.protect(input)

        #expect(plan.commandCount == 1)
        #expect(plan.preservesCommands(in: plan.protectedText))
        #expect(plan.render(plan.protectedText).hasSuffix("Before.\nAfter."))
    }
}
