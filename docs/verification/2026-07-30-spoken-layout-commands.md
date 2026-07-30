# Spoken layout commands — 2026-07-30

## Outcome

Wordhand now converts exact, standalone `command new line` and
`command new paragraph` clauses inside one dictation into one and two newline
characters respectively. It requires dictated letter/number content on both
sides. Unprefixed, leading, trailing, quoted, or question uses remain literal
rather than being guessed.

The engine protects commands before any local writing-style rewrite with
collision-free opaque tokens and neighboring word anchors. A rewrite is usable
only if every expected token appears exactly once, in order, in its original
anchored segment, with no invented token. Otherwise the deterministic protected
source becomes authoritative. Restoration removes separator commas, restores
exact boundaries, and capitalizes the first English letter after them. It
touches no unrelated formatter newline or indentation and cannot expose an
internal token.

## Oracle-first evidence

The new `SpokenLayoutCommandEngineTests` initially failed to compile because
the engine did not exist. After implementation, the focused safe gate passed
the pure engine and macOS adapter suites. The matrix covered:

- period- and comma-delimited reserved line and paragraph commands;
- exact one/two-newline restoration and post-break capitalization;
- ordinary “new paragraph,” “new line item,” quoted reserved commands,
  leading, trailing, missing-content, and question language remaining
  unchanged;
- multiple-command order plus missing, duplicated, reordered, moved,
  case-varied invented token rejection;
- more than 1,000 occupied marker namespaces selecting a genuinely unused
  collision-free namespace;
- formatter-produced multiline indentation remaining byte-for-byte unchanged
  when no command is present;
- direct deterministic processing;
- successful formatter token preservation; and
- two rejected formatter attempts falling back to the exact protected source.

Command:

```sh
WORDHAND_SAFE=1 swift test \
  --filter SpokenLayoutCommandEngineTests \
  --filter GlobalInputAdapterTests
```

After the review-driven adversarial cases, the focused gate passed 35 tests in
2 suites in 1.112 seconds. The complete safe gate passed 280 tests across 31
suites in 1.735 seconds. The release build passed with warnings treated as
errors, and both packaging guards passed:

```sh
WORDHAND_SAFE=1 swift test
WORDHAND_SAFE=1 swift build -c release -Xswiftc -warnings-as-errors
WORDHAND_SAFE=1 ./scripts/test-packaging-guards.sh
```

## Real offline processing path

The public formatter command was driven directly:

```sh
WORDHAND_SAFE=1 .build/debug/wordhand format \
  'First thought, command new line, second thought, command new paragraph, final thought.' \
  --style formatted --application TextEdit
```

Observed output:

```text
First thought
Second thought

Final thought.
```

Semantic and question controls remained literal through the same command.

## Audio-to-format receipt

Three Samantha fixtures made the grammar decision evidence-based. Bare layout
phrases decoded reliably but were rejected as the product grammar because they
are textually indistinguishable from semantic speech:

```text
First thought, new line, second thought, new paragraph, final thought.
```

`Wordhand new line` was explicit but Large v3 decoded it as `word and new line`,
even with default vocabulary conditioning. The selected reserved namespace
decoded exactly:

```text
First thought, command new line, second thought, command new paragraph, final thought.
```

The opt-in receipt generated that fixed final utterance at 185 words per
minute, invoked the actual cached `whisper-large-v3` benchmark subprocess,
asserted the exact decode above, and passed it through the real Formatted /
TextEdit command path:

```sh
WORDHAND_SAFE=1 WORDHAND_LAYOUT_AUDIO_RECEIPT=1 \
  swift test \
  --filter syntheticLayoutCommandsSurviveDecodeAndOfflineFormatting
```

Result: the final post-review run passed in 49.364 seconds. The model reported cached local
loading with network disabled. No microphone, clipboard, event tap, synthetic
keyboard input, installed-app replacement, or process restart was used.

## Remaining boundary

This proves one fixed synthetic English voice and the real offline model /
formatter path. It does not prove natural voices, noisy rooms, alternate
punctuation, or field delivery. `/Applications/Wordhand Dev.app` build 22
remained untouched as PID 7994.
