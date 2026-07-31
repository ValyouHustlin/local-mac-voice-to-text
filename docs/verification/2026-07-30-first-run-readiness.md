# Fresh-Mac readiness and recoverable model preparation

Date: 2026-07-30

## Outcome

Fresh bundled installs have one compact native Welcome window instead of
discovering permissions and model state through unrelated failures. It explains
the default Control-Space gesture, reports Accessibility, Input Monitoring,
Microphone, and the selected local model independently, and enables
`Start Dictating` only when all four are ready.

Window presentation performs status reads only. Each system permission action
remains explicit. Closing the window before readiness does not mark onboarding
complete. Startup does not attempt the global hotkey tap until Accessibility
and Input Monitoring are both ready. Existing settings files migrate to the
current completion version so upgrades do not unexpectedly reopen first-run UI.

Model warmup now publishes Preparing, Ready, or Unavailable to Welcome and
Settings. A transient failure exposes `Try Again`; the controller moves to
Preparing before invoking the retry and ignores further clicks until another
failure. Successful preparation remains authoritative only after the same
full local model warmup and pending-capture recovery path completes.

## Automated evidence

Focused core settings gate:

```text
WORDHAND_SAFE=1 swift test --filter SettingsTests -Xswiftc -warnings-as-errors
14 tests in 1 suite passed in 0.003 seconds
```

Focused macOS adapter and presentation gate:

```text
WORDHAND_SAFE=1 swift test --filter GlobalInputAdapterTests \
  -Xswiftc -warnings-as-errors
45 tests in 1 suite passed in 1.090 seconds
```

The macOS gate includes direct checks that presentation invokes zero permission
request/open-settings methods, incomplete readiness cannot persist completion,
complete live readiness does persist it, early close stays pending, microphone
repair routes by authorization state, and one failed model preparation accepts
exactly one retry. A runtime routing truth table also proves that hotkey edges
cannot reach the coordinator unless the listener, microphone, and model are all
ready. A simulated return from System Settings proves the Welcome window
refreshes permission truth and invokes runtime reconciliation.

## Visual evidence

```text
WORDHAND_SAFE=1 \
WORDHAND_ONBOARDING_RENDER_RECEIPT=1 \
WORDHAND_ONBOARDING_RENDER_OUTPUT=/tmp/wordhand-onboarding.png \
swift test --filter rendersFreshMacReadinessWithoutClipping \
  -Xswiftc -warnings-as-errors
1 test passed in 0.071 seconds
sips: 560 x 560 pixels
```

The rendered dark-mode receipt was inspected at original resolution. The
headline, privacy statement, four readiness rows, three visible recovery
actions, explanatory footer, and disabled primary action were legible and
unclipped.

Thread Sanitizer focused gate:

```text
WORDHAND_SAFE=1 swift test --sanitize=thread \
  --filter 'runtimeRoutesHotkeysOnlyAfterMicrophoneAndModelAreReady|runtimeReconcilesMicrophoneChangesWithoutRestartingTheHotkey|onboardingRefreshesPermissionsWhenItBecomesKeyAgain|unavailableModelRetryStartsExactlyOneNewPreparation' \
  -Xswiftc -warnings-as-errors
4 tests in 1 suite passed in 0.274 seconds
```

Final source gates:

```text
SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 WORDHAND_SAFE=1 swift test
333 tests in 34 suites passed in 5.682 seconds

WORDHAND_SAFE=1 swift build -c release -Xswiftc -warnings-as-errors
Build complete in 9.25 seconds

WORDHAND_SAFE=1 ./scripts/test-packaging-guards.sh
development login-item registration blocked
unsigned release identity blocked

git diff --check
clean
```

## Unexercised boundaries

- No microphone, global event tap, clipboard, or insertion path was started.
- The installed development app was not replaced or driven.
- A fresh macOS account has not exercised the real system permission panels or
  first model download.
- Developer ID identity continuity, notarization, update replacement, login-item
  continuity, and privacy-permission survival remain unproved.

## Discovered release blockers

The tagged release workflow currently publishes an unsigned command-line
archive. The legacy curl installer extracts that archive without authenticating
it. The app installer verifies that its staging bundle is signed, but does not
yet compare candidate and installed bundle ID, Team ID, designated requirement,
and canonical path. These are tracked for the next release-path slice.
