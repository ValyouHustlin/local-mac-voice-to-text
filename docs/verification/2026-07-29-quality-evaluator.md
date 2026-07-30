# Local Quality Lab evaluator — 2026-07-29

## Scope

Turn retained Quality Lab audio plus user-authored corrected references into a
repeatable, fully local model-comparison tool. This evaluates; it does not train
or fine-tune a model.

## Privacy and safety boundary

`wordhand quality evaluate`:

- reads only the selected Wordhand data directory;
- pairs history references and WAVs by transcript UUID;
- uses only completely cached WhisperKit models;
- never downloads a model implicitly;
- never prints transcript or reference text;
- sends no audio, transcript, metric, dictionary entry, or identifier over the
  network;
- does not use the microphone, play audio, install a global event tap, mutate
  the clipboard, or inject text.

The formatter under evaluation is intentionally limited to the local recognizer,
optional dictionary conditioning/substitution, filler cleanup, and deterministic
spoken-repair handling. The generative writing-profile formatter is excluded so
model rankings do not measure paraphrasing.

## Metrics

The evaluator reports micro-averaged totals across the selected corpus:

- normalized word error rate and its clamped accuracy complement;
- normalized spelling character error rate and its accuracy complement;
- normalized exact-match count;
- transcription seconds and real-time factor;
- optional per-record metrics keyed only by local transcript UUID.

Capitalization and sentence punctuation do not change the score. Apostrophes and
hyphens remain meaningful so `we'll` versus `well` and a missing name hyphen are
still visible errors. Corpus totals are summed before division rather than
averaging per-record percentages.

## Model isolation and timeout

An initial four-model pass loaded models sequentially inside one process. Base
and Large v3 completed, but the third Core ML model remained in warmup long
enough that the evaluator had to be terminated manually. No score was claimed
from that attempt.

The final command starts one child process per model, consumes only a JSON metric
report from that worker, and lets the process exit before starting the next
model. Every model is bounded by `--model-timeout-seconds`, defaulting to 180
seconds with a supported range of 30–900. A timed-out worker receives TERM,
then KILL if it does not exit within three seconds. No partial score is accepted.
Worker output is drained concurrently so a large `--details` report cannot fill
the process pipe and deadlock.

## Current live-corpus receipt

The local store contained 14 retained recordings and zero corrected references.
The evaluator did not invent labels or mutate live history.

Exact command:

```sh
WORDHAND_SAFE=1 .build/debug/wordhand quality evaluate
```

Observed:

```text
Error: No corrected references are available. In Wordhand History, choose
Improve Transcript Accuracy for a retained recording, then run this command
again.
```

This is the correct current result. Model ranking becomes meaningful only after
Aaron saves corrected references from History or the menu-bar improvement
action.

## Isolated end-to-end receipt

A temporary data directory received one 3.61-second Samantha-voice fixture:

```text
The quick brown fox jumps over the lazy dog. Send it Monday.
```

The fixture was converted to 16 kHz mono WAV, paired to one temporary history
row with the same corrected reference, evaluated, and deleted afterward. No live
Wordhand history was changed.

The final single-model path was driven with:

```sh
WORDHAND_SAFE=1 .build/debug/wordhand quality evaluate \
  --data-directory /tmp/wordhand-quality-final.<random> \
  --model whisper-base.en \
  --without-dictionary \
  --details \
  --model-timeout-seconds 180
```

Observed:

```text
corpus: 1 paired corrected recording(s) of 1 labeled
network: disabled; complete cached models only
model: whisper-base.en
audio: 3.61s
transcription: 0.140s
real-time factor: 0.039x
normalized word error rate: 0.00%
normalized spelling error rate: 0.00%
normalized exact: 1/1
```

The isolated four-model ranking path also completed against the identical
fixture:

| Model | Warmup | Transcription | Real-time factor | WER | Spelling error |
| --- | ---: | ---: | ---: | ---: | ---: |
| Whisper Base English | 6.369s | 0.137s | 0.038x | 0.00% | 0.00% |
| Whisper Large v3 | 48.706s | 0.808s | 0.224x | 0.00% | 0.00% |
| Whisper Large v3 Turbo | 146.840s | 0.559s | 0.155x | 0.00% | 0.00% |
| Whisper Small English | 17.337s | 0.260s | 0.072x | 0.00% | 0.00% |

All four exact scores on one simple synthetic sentence prove corpus pairing,
model isolation, scoring, privacy-safe reporting, and ranking output. They do
not establish that Base is generally more accurate than Large v3. The unusually
slow warmups are observed current-machine behavior and are reported rather than
hidden; steady-state ranking uses transcription latency after warmup.

## Automated gates

Focused tests cover:

- capitalization and sentence-punctuation normalization;
- proper-name spelling errors;
- meaningful apostrophes and hyphens;
- corpus-level aggregation instead of percentage averaging;
- empty-reference refusal;
- repeated model parsing and safe defaults;
- conflicting selection and unbounded-timeout rejection.

Full suite:

```sh
WORDHAND_SAFE=1 swift test
```

Observed:

```text
Test run with 154 tests in 18 suites passed after 1.161 seconds.
```

Warnings-as-errors production build:

```sh
WORDHAND_SAFE=1 swift build -c release -Xswiftc -warnings-as-errors
```

Observed:

```text
Build complete! (10.34s)
```

A medium-effort first-pass review found no blocking correctness or privacy
issue. It specifically checked worker lifecycle and timeout behavior, concurrent
pipe draining, cached-model enforcement, corpus aggregation, and transcript-text
redaction.
