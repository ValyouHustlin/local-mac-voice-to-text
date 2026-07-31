# Private release-latency oracle verification — 2026-07-30

## Outcome

Wordhand now distinguishes the time spent speaking from the time spent waiting
after release. One monotonic clock starts when the coordinator accepts the stop
gesture, before capture shutdown and queued-audio drain. The same release
timestamp produces cumulative milestones for:

- capture and forwarding drain;
- authoritative raw-text readiness;
- formatted-text readiness; and
- insertion completion.

The private report shows average stage milestones plus median and p95
release-to-insertion. The existing recording-inclusive total is now labeled
`recording through completion` instead of `end-to-end`.

This changes measurement only. Capture, full-buffer transcription authority,
tail recovery, formatting, History-before-insertion, and insertion behavior are
unchanged.

## Oracle-first evidence

The first focused test failed to compile because the report did not yet expose
the five release-latency summaries. The completed deterministic oracles prove:

- release timing starts before `capture.stop()` and forwarding drain;
- one controlled clock produces exact 0.25-second capture drain, 2-second raw
  text, 3-second formatted text, and 3.5-second insertion milestones;
- each report aggregate accepts its metric only from the owning lifecycle
  event, so a misplaced value cannot pollute the summary;
- legacy events with missing milestones remain readable and omit unavailable
  values; and
- the report uses explicit raw-text, formatted-text, insertion, and
  recording-through-completion labels.

The focused gate passed four tests across the coordinator, diagnostics store,
and report formatter suites with warnings treated as errors.

The first full-suite run then exposed two legacy clock fixtures that modeled
the old call count. One exhausted its destructive two-value clock; after that
correction, another still mapped the new capture-ready read onto the old
transcription-start value and reported 9.25 seconds instead of 0.75. Per the
fresh-context rule, a separate audit inspected every injected coordinator clock
before the final correction. Five affected-path tests then passed together.
The architecture now requires that any added monotonic read audit every
injected clock sequence rather than patching failures one at a time.

## Close gates

- `WORDHAND_SAFE=1 swift test`: 409 tests across 39 suites passed in 1.813
  seconds.
- `WORDHAND_SAFE=1 swift build -c release -Xswiftc -warnings-as-errors`:
  passed in 17.91 seconds.
- `WORDHAND_SAFE=1 ./scripts/test-packaging-guards.sh`: all six identity,
  distribution, login-item, and update-continuity guards passed.
- `/bin/bash -n scripts/*.sh` and `git diff --check`: passed with no output.
- Independent neutral review verdict: ship, with no correctness, privacy,
  compatibility, or claim finding at or above 80% confidence.
- Source commit `65cf8be` was pushed to `origin/master`. GitHub CI run
  `30606762014` passed its tests, packaging guards, and release build in 6
  minutes 1 second.
- A development candidate was built as version `0.1.0` build 25 with bundle
  identifier `com.valyou.wordhand.dev`, signed by `Wordhand Local Signing`, and
  passed strict signature verification. It was not installed or launched.
- The installed app remained build 22, running as PID 72243; the process had
  restarted through ordinary user activity before this checkpoint, not through
  the verification work.

## Live read-only compatibility receipt

The current debug command read the installed build-22 diagnostic archive
without exercising capture or global input. It loaded 311 events, 33
dictations, 32 transcriptions, 19 tail audits, and 15 full-buffer retries.
Legacy events correctly omitted every new release milestone. The former
`p95 end-to-end` line rendered as `p95 recording through completion: 92.28s`.

No transcript text, vocabulary, prompt, audio, clipboard, microphone, event
tap, playback, or insertion path was read or exercised.

## Claim boundary

This proves call ordering, event emission, stage-scoped aggregation, formatting,
and legacy compatibility. It does not claim a latency improvement or installed-
build milestone data. Those require installing the signed candidate and
observing attended natural dictation.
