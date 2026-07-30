# Independent long-dictation tail audit — 2026-07-29

## User report and root cause

Aaron reported that a completed dictation had lost one or two sentences from
its ending. The retained Quality Lab artifact made this reproducible without
using the microphone, global hotkey, clipboard, or text injection.

Observed local evidence:

- captured WAV duration: 65.09 seconds;
- sustained speech continued through 61.39 seconds;
- the final 3.68 seconds were silence;
- stored raw transcript length: 316 characters;
- processed transcript length: 310 characters;
- the stored raw and processed text stopped at the same phrase.

Therefore capture was intact and formatting did not delete the ending. Replaying
the complete WAV through the selected Large v3 Turbo Maximum path reproduced
the same truncated transcript. A prompt-free decode recovered multiple later
sentences from the retained audio. Whisper had reported an end-aligned segment,
so the existing timing guard incorrectly treated the truncated result as
complete.

Transcript content is intentionally omitted from this public receipt.

## Fix

For every recording of at least 30 seconds that contains sustained activity in
its final 20-second window, Wordhand now:

1. decodes the final 20 seconds without vocabulary conditioning;
2. keeps the primary result if the independent tail is already covered;
3. appends a tail only after one unique normalized overlap of at least four
   words;
4. runs a complete prompt-free recovery when the tail diverges or cannot prove
   coverage;
5. accepts that full recovery only when it is materially longer and lexically
   aligned.

Recordings under 30 seconds retain the ordinary single-decode path. An
equal-length unconditioned retry cannot replace a conditioned result merely
because its spelling differs.

## Oracle-first tests

The new tests were run before implementation and failed because the independent
audit and reconciliation APIs did not exist. A second oracle exposed a real
reconciliation bug: a recovery containing missing words before a covered suffix
was initially classified as fully covered. That test failed with
`.covered == .requiresFullRetry`, then passed after the branch required the
entire recovery—not only its suffix—to be represented.

Focused command:

```sh
WORDHAND_SAFE=1 swift test --filter TranscriptionIntegrityGuardTests
```

Observed after implementation:

```text
Test run with 23 tests in 1 suite passed after 0.047 seconds.
```

Coverage includes long recordings with late speech, long recordings with a
silent tail, divergent tails, represented tails, missing words before a covered
suffix, ambiguous overlaps, safe merges, and rejection of equal-length
unconditioned replacements.

## Offline real-WAV verification

The exact retained 65.09-second recording was replayed through the real
WhisperKit benchmark path with no playback or microphone access.

Before the independent audit, Large v3 Turbo reproduced the truncation:

```text
path: rolling maximum
audio: 65.09s
stop-to-final: 3.818s
```

With the independent audit, the same model and audio emitted:

```text
transcript integrity tail audit: decoding final 20 seconds without vocabulary prompt
tail audit did not prove complete coverage; falling back to full recovery
transcript integrity retry: decoding without vocabulary prompt
audio: 65.09s
stop-to-final: 10.038s
```

The resulting transcript retained the previously missing ending. This failure
case pays an additional 6.22 seconds to recover multiple sentences; quality is
the explicit priority. A current-code Base replay exercised the same branch in
4.654 seconds stop-to-final and also retained the ending. Normal short
dictations do not receive this additional audit.

## Automated gates

Full suite:

```sh
WORDHAND_SAFE=1 swift test
```

Observed:

```text
Test run with 160 tests in 18 suites passed after 1.187 seconds.
```

Warnings-as-errors release build:

```sh
WORDHAND_SAFE=1 swift build -c release -Xswiftc -warnings-as-errors
```

Observed:

```text
Build complete! (14.01s)
```

## Installed build

Development build 17 was installed before this new bug was diagnosed:

```sh
WORDHAND_SAFE=1 WORDHAND_BUILD_NUMBER=17 ./scripts/install-app.sh
```

Observed:

```text
Version 0.1.0 (17)
Channel: development
Bundle identifier: com.valyou.wordhand.dev
Signature: Wordhand Local Signing
Installed /Applications/Wordhand Dev.app
```

After a normal launch, the installed process remained alive and `doctor`
reported Microphone, Accessibility, Input Monitoring, and Control-Space as
ready.

The corrected implementation was then installed as build 18:

```sh
WORDHAND_SAFE=1 WORDHAND_BUILD_NUMBER=18 ./scripts/install-app.sh
```

Observed:

```text
Version 0.1.0 (18)
Channel: development
Bundle identifier: com.valyou.wordhand.dev
Signature: Wordhand Local Signing
Installed /Applications/Wordhand Dev.app
```

After a normal launch, the canonical installed process remained alive. The
bundle reported build 18 and the same stable signing authority. Installed
`doctor` again reported Microphone, Accessibility, Input Monitoring, and
Control-Space as ready. No live microphone, hotkey gesture, clipboard mutation,
or text injection was exercised during installation verification.
