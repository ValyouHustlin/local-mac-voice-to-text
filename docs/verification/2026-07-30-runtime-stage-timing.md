# Private runtime stage-timing verification — 2026-07-30

## Outcome

Wordhand now preserves three numeric durations it already measures during local
transcription: primary decode, independent tail-audit decode, and full-buffer
retry decode. The private report counts every full-buffer retry and averages
only positive finite values for each stage.

These measurements do not alter capture, transcription selection, formatting,
History, or insertion. They exist to show where stop-to-final time is spent
before another optimization is considered. Legacy diagnostics remain readable
and omit unavailable averages instead of treating missing stages as zero.

## Measured reason for the slice

The read-only metadata report from the running build-22 history showed:

```text
transcriptions: 28
tail audits: 18
tail recoveries: 14
full-buffer retries: 14
median transcription: 5.56s
p95 transcription: 9.84s
average formatting: 2.57s
```

Build 22 did not persist the three stage durations, so no stage-average claim
can be made from those existing events.

## Oracle-first evidence

The initial focused test failed to compile because
`OperationalDiagnosticsReport` did not expose the retry count or three stage
averages. The completed oracles prove:

- the coordinator emits the exact durations supplied by the transcriber;
- only `transcription.completed` events contribute to stage summaries;
- missing, zero, negative, and legacy values do not enter stage averages;
- the existing categorical flag counts full-buffer retries independently of
  their cause;
- report labels say decode and full-buffer explicitly;
- known payload keys are rejected in numeric metrics as well as attributes;
- NaN and positive or negative infinity fail before any write; and
- rejected events do not damage an existing healthy log.

The focused gate passed 13 tests across the diagnostics store, coordinator, and
macOS adapter suites. The real read-only CLI loaded 271 legacy events without a
malformed-line regression and rendered the full-buffer retry count while
omitting unavailable stage averages.

## Close gates

- `WORDHAND_SAFE=1 swift test`: 407 tests across 39 suites passed in 1.957
  seconds.
- `WORDHAND_SAFE=1 swift build -c release -Xswiftc -warnings-as-errors`:
  passed in 23.48 seconds.
- `WORDHAND_SAFE=1 ./scripts/test-packaging-guards.sh`: all six identity,
  distribution, login-item, and update-continuity guards passed.
- `/bin/bash -n scripts/*.sh` and `git diff --check`: passed with no output.
- Independent diff review verdict: ship, with no findings at or above the
  requested 80% confidence threshold.

## Privacy and claim boundary

The new persisted values are durations and one existing boolean category. No
transcript, vocabulary, prompt, sample, or audio payload is added. The store
continues to retain data locally for at most 90 days under its 250 MB ceiling.

This proves source emission, persistence, aggregation, formatting, legacy
compatibility, and privacy rejection through deterministic tests plus the real
local report reader. It does not prove stage timings from a natural dictation,
installed build behavior, stop-to-final improvement, or any new transcription
authority path. Those require build installation and accumulated runtime
evidence.
