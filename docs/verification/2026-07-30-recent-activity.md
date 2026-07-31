# Native Recent activity receipt — 2026-07-30

## Outcome

Settings now presents one compact, read-only summary of evidence Wordhand
already keeps on the Mac. The seven-day row shows unique completed dictations,
failure events, typical end-to-end completion time, and unique recovered
endings. A second row shows corrected transcripts and the subset that still
have paired Quality Lab recordings.

There is no health score, accuracy percentage, status color, threshold, event
browser, new setting, or silent behavior change. The existing Open Folder and
Copy Health Report actions remain in the same card.

## Deterministic contract

The pure snapshot captures `generatedAt` once and includes valid events from
the inclusive rolling 168-hour window through that timestamp. It excludes
future events. Completed and tail-recovered dictations are deduplicated by
dictation UUID. Duplicate completion events use the latest event; their median
accepts only finite, nonnegative `total_seconds` values and averages the middle
pair for an even count. Errors remain failure-event counts, including
session-level errors, rather than an invented failed-dictation count.

History contributes only UUIDs whose corrected reference is nonempty. Quality
Lab contributes only retained WAV UUIDs. Their intersection is the paired
recording count. No transcript, reference, audio, path, model, application,
prompt, dictionary, or failure text enters or persists in the snapshot.

## Focused evidence

The warnings-as-errors focused run passed 67 tests across the diagnostics,
History, Quality Lab, Settings, and macOS adapter suites in 1.029 seconds. The
snapshot plus stale-refresh subset passed 6 tests under Thread Sanitizer in
0.004 seconds with no reported race.

The native SwiftUI card was rendered through AppKit at the actual 516-point
content width available inside the minimum 620-point Settings window. The
observed 516 × 280 PNG showed all four metrics, both evidence counts, the
privacy note, diagnostics retention context, and both existing detail controls
without clipping or overlap.
The isolated render test passed in 0.066 seconds.

The loaded-state fixture displayed:

```text
42 completed
1 issue event
Typical completion 2.1s
2 endings recovered
3 corrected transcripts
2 paired recordings
```

Controller oracles prove that a suspended older refresh cannot replace a newer
result and that a store read failure publishes unavailable rather than a
zero-valued snapshot.

The final serialized safe suite passed 322 tests across 34 suites in 5.628
seconds. The release build completed in 17.48 seconds with warnings treated as
errors. Both packaging safety guards passed, and `git diff --check` completed
with no output.

The neutral review first rejected two misleading labels: the card-level
seven-day caption appeared to include all retained correction evidence, and
`Open Folder` no longer identified the Diagnostics directory. The final card
scopes the activity row to seven days, labels the correction row as all
retained evidence, restores the 90-day/250 MB Diagnostics context, and names
the action `Open Diagnostics Folder`. The re-review verdict was `SHIP`.

## Claim boundary

This proves deterministic aggregation, privacy boundaries, refresh ordering,
and the native loaded-state layout from local fixtures. It does not prove that
the currently installed build displays the card, that a fresh natural
dictation contributes a completion event, or that the accumulated evidence
implies any accuracy level. No microphone, clipboard, global input, insertion,
installed-app replacement, or runtime restart was used.
