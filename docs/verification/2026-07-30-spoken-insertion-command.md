# Additive spoken insertion verification

Date: 2026-07-30

## Product contract

Wordhand can add an omitted phrase after one uniquely matched anchor earlier in
the current dictation:

```text
command correction, insert <new phrase> after <anchor phrase>
```

The command must be the final standalone clause. Each phrase is limited to
1–8 lexical tokens and 80 characters, `after` must occur exactly once, and the
anchor must have one case-insensitive Unicode token-bounded match in the body.
The inserted phrase keeps its dictated casing exactly.

The operation is strictly additive: it inserts one space plus the new phrase at
the anchor's upper boundary and removes only the terminal command suffix. It
does not delete or replace any body byte. It reads no active document, cursor,
selection, clipboard, or surrounding text.

Missing, repeated, subword, decimal, dotted-identifier, already-adjacent,
malformed, embedded, quoted, question, oversized, or nonterminal commands
preserve the literal cleaned transcript. Rejection bypasses every formatter and
emits only the existing text-free reason enum.

## Oracle-first receipt

Before implementation, five insertion checks failed with
`rejected(malformed_command)` because only `replace … with …` existed:

```text
WORDHAND_SAFE=1 swift test --filter \
  'insertsOneExactPhraseAfterOneUniqueAnchorWithoutRemovingBodyText|\
insertionRequiresOneExactUniqueBoundedAnchor|\
malformedOrAmbiguousInsertionCommandsFailClosedByteForByte|\
appliesAdditiveInsertionAfterImmediateRepairs|\
rejectedAdditiveInsertionPreservesTextAndReportsReason'
Test run with 5 tests in 2 suites failed with 26 issues.
```

After implementation, the focused deterministic and integration set passed:

```text
WORDHAND_SAFE=1 swift test --filter \
  'retainedFixtureIdentitiesAndExpectedEditsAreBound|\
appliedInsertionFormatsOnlyTheEditedBodyAcrossWritingProfiles|\
rejectedInsertionBypassesFormatterAndPreservesLiteralCommand|\
acceptedInsertionReachesHistoryBeforeInsertionWithoutCommandText|\
rejectedInsertionIsLiteralAndDiagnosticRemainsTextFree|\
SpokenReplacementCommandEngineTests|\
appliesAdditiveInsertionAfterImmediateRepairs|\
rejectedAdditiveInsertionPreservesTextAndReportsReason'
Test run with 17 tests in 5 suites passed after 0.122 seconds.
```

The checks cover unique anchors, multiword Unicode names, case-insensitive
anchors with exact insertion casing, explicit negation, technical terms,
missing/repeated/overlapping/subword/numeric/domain targets, duplicate
prevention, malformed commands, processor ordering after immediate repairs,
all four writing profiles, formatter bypass on rejection, and
History-before-insertion.

## Retained speech evidence

The public fixture
`Tests/Fixtures/english-spoken-insertion-positive-v1.aiff` was generated without
playback by `/usr/bin/say`, Samantha, 185 words per minute. The manifest binds:

```text
audio duration: 9.154104s
native: 22,050 Hz / 201,848 samples
decoded: 16,000 Hz / 146,466 samples
audio SHA-256: 4a0eba78aa156b0065031fa6849af90ef62f3496bfe64053b99e5fad2e3db5ea
```

The cached, network-disabled authoritative full-buffer Large v3 path decoded
the same complete text four times:

```text
iteration 1: exact, 1.101s
iteration 2: exact, 1.095s
iteration 3: exact, 1.091s
iteration 4: exact, 1.109s
```

Every run retained the opening boundary, terminal namespace, inserted phrase,
unique anchor, and ending boundary. Both the deterministic Casual command and
the real on-device Formatted command returned:

```text
Boundary amber begins this insert test. The release happens Friday at noon. Boundary copper ends the dictated body.
```

The complete four-fixture corpus receipt then replayed every retained audio four
times and drove every bound decode through the real formatter command:

```text
WORDHAND_REPLACEMENT_AUDIO_RECEIPT=1 WORDHAND_SAFE=1 \
  swift test --filter retainedAudioDecodesAndFormatsDeterministically
16/16 authoritative decodes and 4/4 formatter outputs matched.
Test passed after 46.428 seconds.
```

## Source checkpoint

```text
SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 WORDHAND_SAFE=1 swift test
Test run with 378 tests in 38 suites passed after 6.138 seconds.

WORDHAND_SAFE=1 swift build -c release \
  -Xswiftc -warnings-as-errors
Build complete! (18.34s)

WORDHAND_SAFE=1 ./scripts/test-packaging-guards.sh
6/6 guards passed.

/bin/bash -n scripts/*.sh
exit 0

git diff --check
exit 0
```

Independent neutral review returned `SHIP` with no correctness, regression, or
fail-closed finding at or above 80% confidence. It independently ran the
focused engine/processor/coordinator/fixture filter before the final
diagnostic-only integration test was added; that review run passed 16 tests in
5 suites, and the final focused run passed 17.

## Safety boundary

- No microphone, speaker playback, event tap, clipboard, insertion target,
  application install, or Wordhand restart was used.
- The synthetic Samantha fixture proves stable local decoding, not natural
  pronunciation or attended daily use.
- The installed build remains unchanged.
