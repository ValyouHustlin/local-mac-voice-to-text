# Rejected cumulative-prefix authority candidate — 2026-07-30

## Decision

The first executable cumulative-prefix plus overlapping-suffix candidate is
rejected for daily runtime. It preserved every retained transcript only by
falling back to the complete-buffer authority path, reused zero samples, and
increased stop-to-final latency. The normal app configuration remains
`fullBufferControl`.

## Candidate and fail-closed contract

The experiment exists only behind
`cumulativePrefixAuthorityExperiment`, selected by the offline
`models authority-compare` command. It:

- decodes cumulative sample-zero snapshots every eight audio seconds while a
  retained fixture is fed at 2x real time;
- binds snapshots, release, and suffix to session, generation, model,
  vocabulary SHA-256, decoder configuration, language, and exact audio-prefix
  SHA-256;
- freezes the last completed stable prefix before cancelling in-flight work;
- requires finite ordered timestamp coverage inside the supplied snapshot;
- decodes a 12-second-overlapping suffix through the same conditioned decoder;
- requires one unique normalized overlap of at least six words beginning at
  suffix word zero, so unmatched leading suffix text can never be dropped; and
- falls back to a full-buffer decode on every rejected state. A later integrity
  full retry clears any reuse claim.

The aggregate corpus gate additionally requires every measured run of the same
long fixture to report `authorityPath=composed` with
`reusedSampleCount > 0`, and that fixture must have a lower long median.
Equivalent or intermittently composed fallback text cannot pass promotion.

## Oracle-first evidence

Tracker tests were observed failing to compile before the production tracker
and provenance types existed. The final focused command:

```sh
WORDHAND_SAFE=1 swift test \
  --filter 'CumulativeTranscriptSnapshotTrackerTests|StreamingAuthorityComposerTests|StreamingTranscriptStabilizerTests'
```

passed 32 tests across three suites. Coverage includes stale sessions and
generations, non-increasing snapshots, provenance mismatch, malformed hashes,
out-of-bounds timestamps, correction revocation, correction-horizon behavior,
timestamp drift with exact word agreement, unmatched suffix-leading text,
ambiguous overlap, and the full-buffer default.

## Retained corpus replay

Command:

```sh
WORDHAND_SAFE=1 ./scripts/test-transcription-authority-corpus.sh 2
```

The command intentionally exited 1 because the new promotion requirements were
not met. Its aggregate JSON reported `everyComparisonPassed: true`: all three
fixtures preserved every protected beginning, ending, number, negation,
technical term, dictionary spelling, and repeated anchor with no WER or CER
regression.

Observed medians and authority provenance:

| Fixture | Full buffer | Candidate | Candidate authority |
| --- | ---: | ---: | --- |
| 12.572 s lexical | 1.399 s | 1.409 s | full buffer; no stable prefix |
| 49.260 s boundary | 6.291 s | 8.732 s | full buffer; insufficient overlap |
| 53.714 s ambiguity | 4.710 s | 7.322 s | full buffer; insufficient overlap |

Both long boundary runs completed five pre-release decodes; both ambiguity runs
completed six. Every candidate run reported zero reused samples.

## Why it failed

Large v3 emitted only one or two coarse segments over the 49.26-second fixture,
so a trailing two-segment correction horizon could not certify a prefix.
Enabling WhisperKit word timestamps made successive text agreement observable,
but some decoded word ranges were outside the supplied snapshots (for example,
9.90–29.12 seconds for an 8.00-second snapshot and up to 50.62 seconds for a
32.00-second snapshot). Those snapshots correctly failed coverage validation.

Later valid snapshots certified text, but the independently decoded suffix did
not reproduce one exact six-word boundary from its first word. The composer
returned `insufficientOverlap`; Wordhand did not drop, duplicate, or promote
partial text.

Two corrections were attempted—word-level timestamps, then text agreement
independent of timestamp drift. The same promotion failure remained, so this
issue must move to fresh context rather than accumulate another splice
heuristic.

## Runtime boundary

No microphone, playback, clipboard, event tap, insertion target, installed app,
or natural dictation was exercised. The experiment is not selected by daily
runtime and does not authorize a user-visible latency claim. A future attempt
should first evaluate decoder-native state/cache reuse or a deterministic
audio-boundary alignment oracle.
