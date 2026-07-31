# Event-driven insertion verification — 2026-07-31

## Outcome

Paste delivery verification no longer pays an unconditional 360 ms wait when
the exact focused Accessibility element reports a selection or value change.
The notification only wakes a fresh element-and-selection verification; it is
not delivery evidence by itself. The existing 360 ms bound remains both the
final-poll fallback for checkpointed targets without usable notifications and
the clipboard-consumption delay for targets that expose no checkpoint.

The one safe retry, terminal no-retry policy, conditional rich-clipboard
restoration, guarded undo, and exact-target revalidation before optional Return
are unchanged.

## Deterministic latency and lifecycle oracle

The fake-backed adapter gate drove the production observer lifecycle without a
global event tap, synthetic key event, microphone, or live target:

- a controlled timeout was held indefinitely while an exact-target
  notification advanced the cursor and completed verification;
- the notification path recorded a synthetic 25 ms verification wait against
  the previous unconditional 360 ms baseline, a 335 ms / 93.1% reduction in
  that stage;
- a target without notification support reached a final timeout poll;
- cancellation fired synchronously during notification registration, resolved
  unavailable, invalidated once, and could not report the unchanged state that
  authorizes a retry;
- a checkpointless target retained exactly one 360,000,000 ns compatibility
  wait before clipboard restoration;
- verified initial delivery, verified retry, target change, unverified
  delivery, terminal no-retry, undo, and optional Return contracts remained
  covered.

The 25 ms value is a deterministic timing oracle, not a measured live app or
field latency.

## Automated verification

Observed from the final source state:

```text
WORDHAND_SAFE=1 swift test
428 tests in 40 suites passed after 1.678 seconds

WORDHAND_SAFE=1 swift build -c release -Xswiftc -warnings-as-errors
Build complete after 19.46 seconds

WORDHAND_SAFE=1 ./scripts/test-packaging-guards.sh
All five packaging guard groups passed

git diff --check
passed
```

The release build and packaging gate emitted only the already-known upstream
FluidAudio warning for its unhandled `benchmark.md`; project warnings-as-errors
still passed.

A neutral first-pass review initially blocked the change on early clipboard
restoration, a pending-to-active cancellation race, and an oracle that could
have passed through timeout. After fixes, re-review returned `ship` with no
findings at or above 80% confidence and independently passed 78 focused tests.

## Claim boundary

No installed app was replaced or launched because Aaron was away. Native,
browser, Electron/terminal, real clipboard restoration, and optional Return
remain unexercised for this build. The source and deterministic lifecycle are
verified; an attended installed-build pass must measure actual paste-to-
confirmation and stop-to-insertion latency before this becomes a daily-runtime
claim.
