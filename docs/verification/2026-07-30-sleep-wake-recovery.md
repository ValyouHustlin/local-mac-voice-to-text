# Wake-gated capture recovery verification — 2026-07-30

## Outcome

Wordhand no longer starts full Whisper recovery while macOS is entering sleep.
The will-sleep notification begins the existing capture-preservation operation
only. The matching did-wake notification waits for that operation, then runs
the ordinary full-buffer recovery once. Duplicate sleep and wake notifications
coalesce.

Quit during the pre-wake boundary synchronously latches termination, waits for
the same preservation task, and does not start transcription. The latch also
suppresses wake recovery that was scheduled just before Quit. Recovery remains
History-only and never automatically inserts text into the formerly focused
application.

## Oracle-first failure

Five lifecycle tests were changed or added before implementation. The focused
command failed to compile because `RuntimeInterruptionController` had no
`systemDidWake()` operation and `SystemSleepObserver` observed only
`NSWorkspace.willSleepNotification`.

The locked tests require:

- no recovery before did-wake, even after capture preservation finishes;
- did-wake to await an unfinished preservation task;
- duplicate will-sleep and did-wake events to produce one preserve/recover pair;
- a wake event without a preceding sleep event to do nothing;
- Quit during sleep preservation to wait without starting recovery;
- Quit to suppress wake recovery requested immediately before or after
  termination begins; and
- the real notification observer to route both configured event names.

The first implementation passed the initial four tests, but independent review
found that Quit did not latch termination before awaiting the preservation
task. A new interleaving test then failed because a did-wake event could start
recovery while Quit was suspended. The synchronous termination latch and the
second wake-before-Quit oracle close both orderings.

## Automated evidence

The focused five-test oracle passed after the corrected implementation:

```sh
WORDHAND_SAFE=1 swift test \
  --filter 'GlobalInputAdapterTests.(systemSleepRecoveryWaitsForWakeAndCapturePreservation|systemWakeWithoutSleepDoesNotRunRecovery|applicationQuitDuringSleepWaitsForSealWithoutRecovering|applicationQuitSuppressesAlreadyScheduledWakeRecovery|workspaceSleepObserverRoutesWillSleepAndDidWakeOnce)' \
  -Xswiftc -warnings-as-errors
```

The broader journal, coordinator, and macOS-adapter gate passed 125 tests across
three suites. The final full safe suite passed 403 tests across 39 suites in
2.138 seconds after a 13.63-second build. The six lifecycle tests passed under
Thread Sanitizer in 0.002 seconds after a 92.92-second instrumented build, with
no reported race.

The microphone-free process fixture was killed with `SIGKILL` and reopened in a
fresh process:

```text
process crash recovery: exact
samples=7 first=2147483648 last=1065353215 checksum=11754212509259895836
```

The release build completed in 18.45 seconds with warnings treated as errors.
All five packaging safety guards passed. Shell syntax validation and
`git diff --check` completed with no output. Independent review returned
`SHIP` with no findings at or above the reporting threshold after the
termination-race correction.

## Claim boundary

This proves deterministic notification routing, preservation/recovery ordering,
coalescing, Quit behavior, and unchanged exact process-restart recovery through
fakes and the isolated process fixture. It does not prove actual macOS
sleep/wake timing, microphone-device buffers, power-loss durability, installed-
app behavior, natural recovered speech, playback, insertion, or visual UI.
Those boundaries require one attended installed-app checkpoint.
