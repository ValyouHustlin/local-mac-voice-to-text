# Fail-closed overlap-composition oracle — 2026-07-30

## Scope

This checkpoint adds the pure promotion gate and repeated-phrase retained
fixture needed before Wordhand can experiment with authoritative incremental
transcription. It does not connect composed text to daily capture, replace the
full-buffer final decode, record audio, or inject text.

## Composition contract

`StreamingAuthorityComposer` receives:

- one release session and exact final sample count;
- a stable cumulative prefix with its covered sample, snapshot sample count,
  and audio SHA-256;
- the SHA-256 of the same snapshot-length prefix of the released final audio;
- a successful or failed overlapping suffix decode; and
- a caller-supplied integrity verdict for the proposed final text.

It returns verified text only after all identities and sample bounds agree and
the longest eligible suffix of the stable prefix occurs exactly once in both
the stable prefix and suffix decode with at least six normalized words.
Original text ranges preserve casing and punctuation. Sample timestamps prove
coverage only; they never remove words.

Every unsafe outcome explicitly requires the existing full-buffer path:

- stale session;
- prefix-audio mismatch;
- invalid sample coverage;
- suffix decode failure;
- fewer than six overlap words;
- repeated/ambiguous overlap; or
- integrity divergence.

The retained ambiguity test constructs its prefix through the first occurrence
of “the complete audio buffer remains authoritative” and a suffix containing
both occurrences. The composer reports `ambiguousOverlap`; it cannot return
composed text.

## Public retained fixture

`Tests/Fixtures/english-ambiguous-overlap-v1.aiff` is Samantha synthetic English
rendered locally at 190 words per minute. It decodes to 859,431 samples at
16 kHz and lasts 53.7144375 seconds. Its audio SHA-256 is
`c5449c6693ba960c3e5526f7e654baabc2d362dcfaa23fbc859ba44e2ec08a01`.

The manifest protects a unique opening and ending, `14.5`, a negation,
WhisperKit, GitHub, Aaron Browne-Moore, and exactly two occurrences of the
six-word ambiguity anchor. The audio and manifest are now the third case in the
aggregate authority corpus.

## Observed offline replay

Command:

```sh
WORDHAND_SAFE=1 ./scripts/test-transcription-authority-corpus.sh 2
```

The three-fixture aggregate exited zero. On the ambiguity fixture:

- the paired baseline and rolling-control transcripts were identical;
- both copies of the protected ambiguity anchor were present;
- every opening, ending, number, negation, technical-term, dictionary, word
  error, and character error check passed;
- full-buffer/control median stop-to-final was 4.728 / 4.729 seconds;
- the control completed 12 pre-release decodes in both runs using 12.71–12.76
  seconds of inference, reused zero samples, and still reported
  `full_buffer_control`;
- primary decode was 3.32 seconds and the independent tail audit was
  1.40–1.41 seconds.

The sub-millisecond timing difference is noise and is not a latency claim. This replay
calibrates the fixture and confirms the current control remains complete; it
does not exercise a composed candidate.

## Focused automated receipt

The oracle-first test was observed failing to compile before the production
types existed. After implementation:

```sh
WORDHAND_SAFE=1 swift test \
  --filter 'StreamingAuthorityComposerTests|TranscriptionCompletenessOracleTests'
```

Twenty-four tests across two suites passed. They cover one unique join,
repeated overlap in either transcript, longer disambiguating context, case and
punctuation normalization, five-word rejection, a caller attempting to lower
the six-word floor, exact and canonical SHA-256 prefix identity, stale
completion, invalid sample coverage, suffix failure, integrity divergence, the
retained fixture's forced fallback, rejection after one repeated anchor is
lost, manifest validation, and audio identity.

Full source checkpoint:

- `WORDHAND_SAFE=1 swift test`: 210 tests across 23 suites passed in 1.755
  seconds;
- `WORDHAND_SAFE=1 swift build -c release -Xswiftc -warnings-as-errors`:
  passed in 12.76 seconds;
- `WORDHAND_SAFE=1 ./scripts/test-packaging-guards.sh`: development login-item
  registration and unsigned release identity were blocked;
- shell syntax, fixture JSON, and `git diff --check`: passed;
- neutral review found one false-evidence blocker: equal arbitrary strings
  could stand in for audio hashes. Canonical lowercase 64-hex SHA-256 validation
  and malformed-hash coverage fixed it; the final verdict was `ship`.

## Unexercised boundaries

No cumulative-prefix decoder, release-time suffix decoder, cancellation state
machine, or runtime fallback wiring exists yet. No microphone, playback,
clipboard, event tap, insertion, application field, or installed application
was exercised. Natural short and long dictation remain mandatory before a
daily-runtime authority change.
