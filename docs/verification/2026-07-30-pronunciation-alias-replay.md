# Pronunciation-alias causal replay — 2026-07-30

## Decision

Wordhand can now prove or reject one evidence-backed pronunciation alias
offline without changing daily dictation or writing user state. The isolated
`Aaron Brown more -> Aaron Browne-Moore` candidate was correctly rejected:
the existing canonical vocabulary already produced the desired spelling, so
the alias added no accuracy and cost decode time.

## Locked design

- Schema 2 requires a distinct bounded `heardAs` value, an enabled canonical
  self-entry, two distinct supporting transcript IDs, six repetitions, and at
  least one unrelated retained recording.
- A pure source oracle must recover the same complete heard/canonical phrase
  from two explicit corrected History rows. The raw transcript must contain the
  heard phrase; number, negation, modal, conflict, and broad-rewrite evidence
  abstains. Only close split/merge spellings with the same initial character
  and distinctive canonical orthography qualify. Ordinary semantic
  substitutions such as `Friday -> Monday` and `every day -> everyday`
  abstain. A future explicit heard-as correction signal is required before
  widening this gate.
- The command derives evidence from a byte-stable private History/WAL snapshot
  and the initial Dictionary bytes. Request text alone is never authority.
- Every recording runs B/K/A, B/A/K, K/B/A, K/A/B, A/B/K, and A/K/B. B is the
  live dictionary; K adds a priority-matched canonical self-entry; A replaces
  that entry with the requested pronunciation association.
- Public prompt snapshots must show identical canonical terms and ordering for
  K and A. Removing the one requested association from A must leave K's exact
  bounded alias list.
- Every scored arm uses the baseline deterministic transcript processor. Only
  decoder output can establish the alias win; fallback replacement cannot
  rescue it.
- A must prove against K for causal attribution and against B for live safety.
  Both decisions must prove for promotion. Reports remain transcript-free and
  contain only hashes, aggregate metrics, counts, verdicts, and reasons.

## Automated and real evidence

The focused matrix passed 37 tests across five suites. It covers complete-term
source extraction, conflicting and unsafe evidence abstention, alias source
presence, semantic-substitution rejection, 4/6 repeatability, request schema
bounds, prompt semantic snapshots, canonical controls, and opt-in receipts.

The real alias receipt generated two Samantha support recordings at distinct
rates plus one numbers/negation boundary control, stored them in an isolated
Quality Lab tree, and drove the public CLI through its bounded cached-model-only
worker:

```text
WORDHAND_SAFE=1 WORDHAND_PRONUNCIATION_REPLAY_RECEIPT=1 \
  swift test --filter \
  VocabularyCandidateReplayReceiptTests.replaysEvidenceBackedAliasAgainstMatchedPriorityControl
```

Observed aggregate against K:

```text
verdict=rejected
word edits=0->0
decode=18.034s->21.222s
reasons include alias_source_not_repeatably_observed,
baseline_already_contains_candidate, no_strict_supporting_improvement,
support_not_repeatably_improved, latency_regression
```

The independent B comparison reached the same disposition. The complete
isolated data-tree membership, modes, sizes, and hashes were identical before
and after. `/usr/bin/time -l` observed 110.71 seconds wall time and 545,472,512
bytes maximum resident set size for build, test host, parent, worker, model,
and all 54 decodes.

The canonical receipt was rerun after removing candidate fallback processing.
It retained the real decoder-conditioned accuracy change (word edits 60 to 36,
character edits 240 to 204) and remained rejected for latency at 44.679 to
54.753 seconds. Wall time was 104.74 seconds and maximum resident set size was
520,437,760 bytes.

These are offline synthesized/retained-fixture receipts, not natural-voice or
daily-runtime claims. No UI suggestion, automatic alias, background job, or
persisted verdict was added.
