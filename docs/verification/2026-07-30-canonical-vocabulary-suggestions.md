# Canonical vocabulary suggestions — 2026-07-30

## Decision

Wordhand now has one fail-closed, suggestion-only local learning slice. It can
notice the same distinctive vocabulary correction across two explicitly
corrected transcripts whose paired Quality Lab recordings still exist, then
offer one noninterrupting History action. It never changes transcription
behavior until the user confirms `Add to Vocabulary`.

The accepted entry uses the canonical term as both `spokenForm` and
`replacement`. It therefore becomes a high-priority decode prompt term without
creating a pronunciation alias or broad post-decode substitution.

## Oracle

`VocabularySuggestionOracle` recomputes evidence from local History,
recording UUIDs, and current Dictionary entries. It requires:

1. two distinct supporting transcript IDs;
2. a retained local WAV for every support;
3. one bounded lexical substitution per corrected record;
4. the changed source words in the raw authoritative decode;
5. one identical, distinctive canonical result;
6. no competing correction or existing canonical dictionary term.

It abstains for one-off corrections, missing recordings, punctuation or case
only, typography, common spelling variants, number and negation changes,
semantic replacements, broad or multiple edits, unsafe phrase merges,
formatter-only mismatches, conflicting corrections, and already-covered terms.
Input order and duplicate rows cannot change output order or support.

## Oracle-first evidence

Before implementation:

```sh
WORDHAND_SAFE=1 swift test --filter VocabularySuggestionOracleTests
```

The build failed because `VocabularySuggestionOracle` did not exist. This
established the executable contract before product code.

After implementation:

```sh
WORDHAND_SAFE=1 swift test --filter \
  'VocabularySuggestionAcceptanceTests|VocabularySuggestionOracleTests|LocalQualityAudioArchiveTests'
```

Result observed: 21 tests in 3 suites passed. The flow proved suggestion
evaluation leaves `dictionary.json` byte-identical, explicit acceptance writes
one enabled `term -> term` entry, the live vocabulary prioritizes it, no
pronunciation guide is generated, ordinary processing remains a no-op for the
canonical spelling, and the now-covered suggestion disappears. Regression
cases preserve `AT&T` exactly, reject unsupported punctuation, add a canonical
self-entry alongside an existing alias, and re-enable a disabled canonical
self-entry only after explicit acceptance.

## Native UI receipt

```sh
WORDHAND_SAFE=1 \
WORDHAND_UI_RECEIPT=/tmp/wordhand-vocabulary-suggestion.png \
swift test --filter \
  'VocabularySuggestionAcceptanceTests|VocabularySuggestionOracleTests'
```

The isolated AppKit History window rendered at 920×620 and was inspected from
the generated PNG. The selected newest support showed:

- the existing corrected-reference status;
- one purple evidence line naming `Kierkegaard` and two corrected transcripts;
- one `Review Suggestion…` button aligned above the existing History actions.

No Wordhand runtime, microphone, event tap, clipboard, or insertion path was
started. This is a native isolated-render receipt, not an installed-app or
natural-dictation claim.

A read-only count against the current Wordhand data directory found zero
corrected references and 37 retained WAVs. The installed app therefore has no
real eligible recommendation to inspect yet; no transcript or audio content was
read or printed. This confirms the remaining yield boundary rather than
promoting the fixture into a daily-use claim.

## Privacy and residual boundary

All evidence remains in local History, owner-only Quality Lab WAVs, and the
local Dictionary. No transcript, term, or audio payload enters diagnostics or
leaves the Mac. Public audio retention remains disabled by default.

This slice does not replay candidate vocabulary against retained audio, infer a
pronunciation alias, recommend a model or configuration, prove yield from
Aaron's current History, or prove a natural recording improves after
acceptance. Those need separate candidate-vs-corpus and attended-use receipts.

## Landing gates

```sh
WORDHAND_SAFE=1 swift test
WORDHAND_SAFE=1 swift build -c release -Xswiftc -warnings-as-errors
WORDHAND_SAFE=1 ./scripts/test-packaging-guards.sh
git diff --check
```

Observed before landing: 242 tests in 27 suites passed; the release build
completed with warnings treated as errors; both development-login-item and
unsigned-release packaging guards passed; the diff check passed. A neutral
review initially found exact-punctuation and stale dictionary-state defects.
After their regressions and fixes, its final verdict was `SHIP` with no
remaining finding at or above 80% confidence.
