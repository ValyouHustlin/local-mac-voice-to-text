# Vocabulary causal replay — 2026-07-30

## Decision

Wordhand now has an explicit offline causal proof for one canonical vocabulary
candidate. It does not gate or alter the History suggestion, persist evidence,
or change daily transcription. The tested public candidate was rejected because
its measured accuracy gain came with a material decode-time regression.

## Locked oracle

- The request is versioned JSON on stdin; the candidate is absent from process
  arguments, bounded to 16 KiB, and redacted from all output.
- One bounded child worker uses a complete cached model and never downloads.
- History database/WAL bytes must match across two consecutive reads before
  they are opened as a private temporary snapshot. The live SQLite database and
  shared-memory sidecar are never opened by SQLite. Dictionary JSON is decoded
  without migration or permission changes.
- Baseline is the current enabled dictionary. Candidate is the same snapshot
  plus one in-memory `term -> term` entry.
- Two distinct supporting audio identities and at least one unrelated paired
  recording are mandatory.
- Every recording runs four times in B/C, C/B, C/B, B/C order.
- Every supporting candidate transcript must contain the exact case- and
  punctuation-preserving canonical spelling.
- Each source must strictly improve word and character edit distance in at
  least three of four repetitions; summed source word and character edits must
  both improve.
- No individual or aggregate word/character regression, protected-content loss,
  exact-match loss, metric-tied text change, or material latency regression is
  accepted.
- Missing, duplicate, malformed, incomplete, or unscorable evidence returns
  `inconclusive`; observed harm returns `rejected`.
- The worker JSON contains model/decoder, candidate, dictionary, corpus, and
  supporting-ID hashes plus counts, durations, verdict, and reasons—never
  transcript, reference, raw candidate, raw UUID, or audio path.
- The report hashes the exact initial dictionary bytes. A concurrent dictionary
  change aborts the run without emitting a stale verdict.

## Oracle-first evidence

The focused suite first failed because the replay types did not exist. After
implementation:

```text
WORDHAND_SAFE=1 swift test --filter \
  'VocabularyCandidateReplay|QualityEvaluationCommand'
10 tests in 3 suites passed
```

The matrix proves a repeatable source win, rejects an unrelated corpus
regression, abstains on missing independent evidence, rejects protected-span
loss, produces the same decision under reversed input order, validates fixed
request bounds, and keeps the cached-model receipt opt-in.

## Real CLI receipt

The opt-in receipt built an isolated data directory from the three checked-in
English retained fixtures, saved two supporting and one control History row,
copied the paired audio under their UUIDs, and drove the public command:

```text
WORDHAND_SAFE=1 WORDHAND_VOCABULARY_REPLAY_RECEIPT=1 \
  swift test --filter VocabularyCandidateReplayReceiptTests
```

The test invoked `.build/debug/wordhand quality prove-vocabulary
--request-stdin --json --data-directory <isolated>`; that parent spawned the
single model worker. Large v3 loaded from the complete local cache with
`network disabled`. The final observed aggregate was:

```text
verdict=rejected
word edits=60->36
character edits=240->204
normalized exact=0->0
decode=37.795s->48.738s
reason=latency_regression
```

The real command exited successfully with a complete rejected verdict; it did
not round the accuracy improvement into promotion. The complete isolated
data-tree snapshot—directory membership, permission modes, file sizes, and
SHA-256 for Dictionary, History, SQLite WAL/SHM, and all audio—was identical
before and after. No Settings file or recommendation cache was created.

`/usr/bin/time -l` observed 135.89 seconds wall time and 548,896,768 bytes
maximum resident set size for build, test host, parent command, isolated worker,
model load, and all replays. This is offline evaluation evidence, not a
daily-runtime latency claim.

## Product disposition

The current History suggestion remains cheap, contextual, and explicitly
confirmed. No synchronous or background replay was added: the live corpus had
zero corrected references, so either design would add model contention and UI
job state with no eligible decision. Persisted replay evidence waits for real
yield and a separate invalidation design. The next bounded learning candidate
is pronunciation-alias replay through this same offline gate.
