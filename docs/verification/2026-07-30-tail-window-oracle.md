# Tail-audit window authority oracle

Date: 2026-07-30

## Outcome

Wordhand now has a deterministic offline oracle for one measured tail-latency
hypothesis: whether a 30-second prompt-free tail decode can establish a safe
unique overlap more often than the current 20-second audit and avoid an
expensive full-buffer retry.

The experiment does not alter daily runtime. Each balanced pair shares the
same primary and prompt-free full-buffer decodes, alternates only the 20s/30s
tail-audit order, and resolves both arms through the existing integrity
reconciliation and selection rules. The report contains hashes, sample
identity, timings, retry flags, outcomes, and coded reasons; an allowlist oracle
forbids transcript, reference, audio-path, vocabulary-term, accepted-form, and
matched-form fields.

Promotion requires valid balanced evidence, stable hashes, byte-exact candidate
agreement with the paired 20-second authority, a bound public fixture satisfying
beginnings/endings/numbers/negations/technical terms/dictionary spelling with
no accuracy regression, fewer full retries, and at least 250 ms plus 5% lower
modeled median stop-to-final. Timing cannot override a content or evidence
failure. Private hashes without protected reference truth cannot promote.

## Evidence-led ranking

Metadata-only inspection observed 139 History rows and 52 retained recordings,
with zero corrected references. Pronunciation/model/configuration suggestions
therefore lack their required real-yield evidence.

Tail evidence was stronger:

```text
full_retry_recovered: 12
average audio: 63.35s (37.99–88.49s)
average transcription: 7.75s
verified_covered: 3
merged: 1
no_improvement: 1
```

Every recovered UUID still had a retained WAV, and UUID-derived durations
matched History metadata to 0.001 seconds. No content was printed.

## Oracle-first receipt

Before implementation:

```text
WORDHAND_SAFE=1 swift test --filter TailAuditWindowComparisonOracleTests
exit=1
cannot find type 'TailAuditWindowRunEvidence' in scope
cannot find 'TailAuditWindowComparisonOracle' in scope
```

After implementation:

```text
WORDHAND_SAFE=1 swift test --filter \
  'TailAuditWindowComparisonOracleTests|QualityEvaluationCommandTests'
Test run with 15 tests in 2 suites passed after 0.019 seconds.
```

Coverage includes exact/stable promotion, transcript mismatch,
nondeterministic authority, absent retry reduction, immaterial latency,
malformed/unbalanced evidence, protected-proof absence, fixed balanced CLI
arguments, rejection of any non-30-second candidate, outcome/retry consistency,
cached evidence selection, and the transcript-free JSON schema. The report
omits the arbitrary fixture ID and identifies fixture evidence only by hash.

## Protected fixture replay

The real local-model replay used no microphone, playback, event tap, clipboard,
or insertion:

```text
WORDHAND_SAFE=1 .build/debug/wordhand models tail-window-compare \
  Tests/Fixtures/english-boundary-long-v1.aiff \
  --fixture Tests/Fixtures/english-boundary-long-v1.json \
  --model whisper-large-v3 --iterations 2 --json
```

Observed:

```text
audioDurationSeconds 49.26
protectedCompletenessPassed True
baselineFullRetryCount 2
candidateFullRetryCount 2
baselineMedian 6.401
candidateMedian 7.302
everyTranscriptIsExact True
candidatePassesPromotionGate False
rejectionReasons full_retry_not_reduced,latency_win_not_material
```

The candidate preserved all protected content but eliminated no retry and was
0.901 seconds slower at the modeled median.

## Private retained recovery probe

The shortest retained `full_retry_recovered` case was selected by UUID and
replayed with a read-only current-dictionary snapshot. Its path and content
were omitted.

```text
audioDurationSeconds 37.987
protectedCompletenessPassed False
baselineFullRetryCount 2
candidateFullRetryCount 0
baselineMedian 6.561
candidateMedian 5.371
everyTranscriptIsExact False
candidatePassesPromotionGate False
rejectionReasons transcript_mismatch,protected_completeness_unproven
```

Both arms were individually deterministic. The candidate merged instead of
retrying, but both hashes differed from the authoritative full recovery. The
oracle rejected the dangerous shortcut; runtime remains unchanged.

## Source checkpoint

```text
SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 WORDHAND_SAFE=1 swift test
Test run with 348 tests in 36 suites passed after 6.060 seconds.

WORDHAND_SAFE=1 swift build -c release -Xswiftc -warnings-as-errors
Build complete! (19.53s)

WORDHAND_SAFE=1 ./scripts/test-packaging-guards.sh
✓ signed update identity fixtures accept only the exact identity
✓ unsafe public distribution paths are retired
✓ release identity, runtime, entitlement, and notarization policy is fail-closed
✓ development login-item registration is blocked
✓ unsigned release identity is blocked
✓ update identity continuity is fail-closed

/bin/bash -n scripts/*.sh
git diff --check
exit 0
```

## Unexercised boundaries

- The other eleven retained recoveries were not decoded because the protected
  fixture and first natural case independently rejected the fixed candidate.
- No natural-voice accuracy claim follows from an output hash.
- No microphone, playback, clipboard, event tap, insertion, installation,
  launch, update, or release action occurred.
