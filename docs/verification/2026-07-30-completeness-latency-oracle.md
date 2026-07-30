# Completeness and latency authority oracle — 2026-07-30

## Scope

This checkpoint adds a deterministic offline promotion gate before any change
to Wordhand's live capture or authoritative full-buffer transcription path.
It does not enable partial transcription in the daily runtime.

## Protected contract

`TranscriptionCompletenessOracle` requires every candidate transcript to:

- preserve explicit beginning and ending spans;
- preserve a number and negation;
- preserve technical terms and dictionary-conditioned spelling;
- have word and character error rates no worse than its paired full-buffer
  baseline.

`wordhand models authority-compare` verifies the fixture's expected audio hash
and decoded sample count, loads that audio once, uses only fixture vocabulary,
requires a cached model, discards one warmup inference pair, then alternates an
even number of baseline/candidate measurements. The report binds model,
implementation and decoder IDs, audio/fixture/vocabulary hashes, sample count,
and sample rate. A fixture missing any of the six required categories fails
closed. Any failed comparison exits nonzero. Timing never overrides accuracy.

## Retained corpus

The checked-in `Tests/Fixtures/english-completeness-v1.aiff` is synthetic
English speech generated locally with the macOS Samantha voice at 105 words per
minute. It is 12.572125 seconds / 201,154 decoded 16 kHz samples. Its companion
JSON defines unique boundary markers, `14.5`, “do not,” `WhisperKit`, `GitHub`,
and `Aaron Browne-Moore`.

`Tests/Fixtures/english-boundary-long-v1.aiff` is 49.259625 seconds / 788,154
decoded 16 kHz samples. It crosses two 20-second rolling boundaries and repeats
the same protected categories with distinct opening and closing markers. Its
audio SHA-256 is
`9fd0eaedd9ca1cae15653093c9d771b53c00cd344ae4d42dcbc01ec011a4c2f3`;
its fixture SHA-256 is
`d737937348185d2a6071b252eb6a336cad89ed63228ba453f91da523722d9804`.

The corpus manifest binds both public cases. The aggregate runner is:

```sh
WORDHAND_SAFE=1 ./scripts/test-transcription-authority-corpus.sh 2
```

An initial calibration pronounced `Valyou` ambiguously. Both paths returned
“valia,” and the new absolute protected-span gate correctly rejected them with
`missing_dictionarySpelling`. That fixture was replaced rather than weakening
the assertion.

## Live offline replay

Command:

```sh
WORDHAND_SAFE=1 .build/debug/wordhand models authority-compare \
  Tests/Fixtures/english-completeness-v1.aiff \
  --fixture Tests/Fixtures/english-completeness-v1.json \
  --iterations 4 --json
```

Observed with cached `whisper-large-v3`:

- audio SHA-256:
  `eec8f372804827a461958e8d5c1f329063c0b40e2b63858bfcfa3c1d38bfbbf1`;
- fixture SHA-256:
  `edc78f9ff57dff4e2e5fb3f6fec610468a4c9f5833c486aa8302725cbec99ada`;
- vocabulary SHA-256:
  `7a8a098f808f4f97f708238bfb666715f19d52beedb39d4ed60dfd313f003765`;
- implementation IDs: `full-buffer-authoritative-v1` and
  `rolling-precompute-full-buffer-final-control-v1`;
- order: baseline/candidate, candidate/baseline, baseline/candidate,
  candidate/baseline;
- full-buffer median / p95 stop-to-final: 1.388 / 1.452 seconds;
- rolling-final median / p95 stop-to-final: 1.388 / 1.405 seconds;
- all eight measured transcripts were identical:
  “Boundary Alpha begins this test. The value is 14.5. Do not deploy on
  Friday. WhisperKit and GitHub support Aaron Browne-Moore. Boundary Omega ends
  this test.”;
- all protected checks passed, all rejection-reason arrays were empty, and the
  control-equivalence gate passed.

The 0.1 ms median difference is measurement noise, not evidence of useful
latency improvement. The named control still performs an authoritative
full-buffer decode at release. Its PASS does not authorize a future incremental
implementation.

The aggregate two-fixture provenance replay also passed:

- short full-buffer/control median: 1.385 / 1.411 seconds;
- long full-buffer/control median: 6.274 / 6.278 seconds;
- every protected result passed and every rejection-reason array was empty.

The long control is 4 ms slower at the median. Each control run completed ten
pre-release rolling decodes using 11.48–11.66 seconds of inference, reused zero
samples, and waited about 10 ms for cancellation. Its release path then
measured:

- conditioned primary full decode: 2.41–2.42 seconds;
- mandatory independent final-20-second audit: 1.20–1.22 seconds;
- conservative prompt-free full retry: 2.65–2.66 seconds;
- authority path: `full_buffer_control`;
- fallback reason: `incremental_authority_not_implemented`.

This is evidence against enabling the current discarded rolling work, not
evidence for a speed claim. It also identifies both reusable work and the
integrity stages a future candidate must preserve.

The corpus runner rebuilds the default debug executable on every invocation
and pins the model plus baseline/candidate implementation IDs in the corpus
manifest. Exit zero requires exact fixture membership, every child comparison
to pass, and every long case to report completed pre-release rolling decodes.
An explicitly supplied binary must already be executable.

## Automated receipt

Focused oracle tests passed nine tests, including five table-driven protected
regressions, duplicate-occurrence rejection, incomplete-manifest rejection,
invalid boundary-placement/reference rejection, and binding the checked-in
manifest to its AIFF hash.

Final source checkpoint:

- `WORDHAND_SAFE=1 swift test`: 195 tests across 22 suites passed in 1.575
  seconds;
- `WORDHAND_SAFE=1 swift build -c release -Xswiftc -warnings-as-errors`:
  passed in 11.25 seconds;
- `WORDHAND_SAFE=1 ./scripts/test-packaging-guards.sh`: development login-item
  registration and unsigned release identity were both blocked;
- neutral review found six blockers across two rounds; all were fixed, and the
  final verdict was `ship`.

GitHub CI is recorded at closeout after the commit is pushed.

Corpus/provenance extension checkpoint:

- `WORDHAND_SAFE=1 swift test`: 195 tests across 22 suites passed in 1.534
  seconds;
- `WORDHAND_SAFE=1 swift build -c release -Xswiftc -warnings-as-errors`:
  passed in 11.62 seconds;
- packaging guards, shell syntax, and `git diff --check`: passed;
- neutral review found three false-evidence/timing blockers; all were fixed,
  and the final verdict was `ship`.

## Unexercised boundaries

No microphone, playback, clipboard, event tap, insertion, application field, or
installed application was exercised. Both voices are the same synthetic
Samantha voice. Broader voice/acoustic diversity plus attended natural short
and long dictation remain mandatory before any daily-runtime authority change.
