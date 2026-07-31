# Empty-transcript recovery

Date: 2026-07-30

## Outcome

Wordhand no longer treats meaningful captured audio with zero recognized text
as a successful empty dictation. The complete conditioned primary remains the
normal authority. Only an empty primary with meaningful activity performs one
prompt-free full-buffer retry. A recovered result follows the ordinary
History-before-insertion path. If the retry remains empty, Wordhand surfaces
`no text recognized · recording kept` and leaves the crash journal recoverable.
Quiet no-speech audio skips the second decode and is discarded.

The same fail-safe boundary applies after restart. Active audio that remains
empty keeps its journal; quiet audio is retired instead of retrying forever.
Formatting that turns nonempty recognition output into empty text also fails
visibly and preserves the recording, including whitespace-only output. A
preserved oldest journal does not block later recoveries in the same scan.
Discard failure is logged and visible rather than reported as quiet success.

## Measured trigger

The private metadata-only diagnostics currently contain one real loss case:

```text
audio_seconds: 27.7904375
sample_count: 444647
rms: 0.017504
peak: 0.223770
active_window_fraction: 0.973022
primary_word_count: 0
final_word_count: 0
transcription_seconds: 1.489
```

The installed build then emitted `processing.empty` without `history.saved`,
`quality_audio.stored`, `insertion.completed`, or `dictation.completed`.
No transcript, audio, prompt, or vocabulary content was inspected. The installed
build predates this source fix and had no pending file for this dictation, so the
historical recording itself was not recovered.

## Oracle-first receipt

Before implementation:

```text
WORDHAND_SAFE=1 swift test --filter \
  'EmptyTranscriptRecoveryPolicyTests|activeAudioWithNoRecognizedText'
exit 1
cannot find 'EmptyTranscriptRecoveryPolicy' in scope
```

After implementation:

```text
SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 WORDHAND_SAFE=1 swift test \
  --filter 'EmptyTranscriptRecoveryPolicyTests|DictationCoordinatorTests|\
preservedOldestCaptureDoesNotBlockLaterRecovery|\
terminalRecoveryFailureStillStopsTheOrderedScan'
Test run with 50 tests in 3 suites passed after 0.073 seconds.
```

The real `CrashSafeCaptureWriter` and `CrashSafeCaptureJournal` are reopened
after an empty decode. The recovered Float32 buffer matches the original sample
count and every bit pattern, including distinct first and last samples.
Additional oracles cover successful retry through History and insertion,
throwing journal cleanup, whitespace-only live and recovered formatting,
continued recovery after a preserved oldest item, and terminal-error stop.

## Protected local-model replay

The real cached local model replay used no microphone, playback, event tap,
clipboard, or insertion:

```text
WORDHAND_SAFE=1 .build/debug/wordhand models authority-compare \
  Tests/Fixtures/english-completeness-v1.aiff \
  --fixture Tests/Fixtures/english-completeness-v1.json \
  --model whisper-large-v3-turbo --iterations 2 --json
```

Observed:

```text
audioDurationSeconds: 12.572125
everyComparisonPassed: true
baseline/candidate transcripts: byte-identical in both runs
emptyTranscriptRecoveryOutcome: not_needed in all four decodes
protected checks: all beginning, ending, number, negation,
technical-term, and dictionary-spelling checks passed
baseline median stop-to-final: 1.140s
candidate median stop-to-final: 1.155s
```

This proves the new branch is inert for this ordinary nonempty protected
dictation. It does not reproduce the historical empty primary on the real model.

## Source checkpoint

```text
SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 WORDHAND_SAFE=1 swift test
Test run with 365 tests in 37 suites passed after 6.011 seconds.

WORDHAND_SAFE=1 swift build -c release \
  -Xswiftc -warnings-as-errors
Build complete! (20.00s)

WORDHAND_SAFE=1 ./scripts/test-packaging-guards.sh
6/6 guards passed.

/bin/bash -n scripts/*.sh
exit 0

git diff --check
exit 0
```

An independent neutral diff re-review returned `SHIP` with no correctness or
cleanup findings at or above 80% confidence. Its first review found three
blocking edge cases: a preserved oldest recording blocked later recovery,
quiet-recording discard errors were suppressed, and whitespace-only formatting
bypassed the empty-output guard. All three were fixed and covered by the
focused 50-test recovery suite before the final review.

## Unexercised boundaries

- The historical empty capture had no retained WAV and cannot prove that the
  prompt-free retry would have recovered its text.
- No natural microphone empty-decode case was manufactured.
- The installed build was not replaced, launched, or restarted.
- Speaker output, clipboard, global input, and insertion were not exercised.
