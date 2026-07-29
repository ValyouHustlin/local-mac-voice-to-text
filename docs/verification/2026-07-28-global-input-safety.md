# Global input safety receipt — 2026-07-28

## Initial report and correction

Wordhand's foreground development runtime was repeatedly launched on Aaron's
shared Mac while other agent lanes were active. The runtime installs a global
`CGEventTap` and its product behavior includes posting synthetic keyboard
events into the focused application.

The Master AI seat initially attributed a suspended Claude Code window, a
SIGINT in another lane, and a missing lane to Wordhand's test runs. That
attribution was later withdrawn. Aaron identified that a keyboard shortcut was
sending Control-Z, which newer Claude Code behavior handles by suspending to
the background shell. `fg` restored the process; the window had not been
closed and work had not been lost.

There is no evidence that Wordhand caused the SIGINT or the missing lane. This
receipt makes no damage claim. The safety controls below stand because an
unattended global event tap and synthetic input path are inherently risky on a
Mac hosting live work, not because Wordhand was shown to have harmed the fleet.

The active Wordhand process was terminated when the rule arrived. A process
table check then returned no `.build/debug/wordhand run`,
`.build/release/wordhand run`, or `wordhand` executable.

## Permanent development rule

Agent lanes must never leave the real event-tap or text-injection paths running
unattended on Aaron's shared Mac. `--skip-doctor` does not make the path
isolated. Necessary live checks are allowed when they are short, deliberate,
time-bounded, and actively attended.

Allowed verification:

- `swift test`;
- debug and release builds;
- offline model benchmarks that do not install global input;
- HotkeyMonitor tests with a fake tap installer;
- MacTextInserter tests with a fake event poster.

## Code controls

`WORDHAND_SAFE=1` makes `wordhand run` refuse startup before data migration,
permission checks, model warm-up, AppKit setup, event-tap creation, audio
capture, or text-injector setup.

HotkeyMonitor now receives a `HotkeyTapInstalling` dependency. Tests provide a
fake controller and observe start/stop behavior without calling
`CGEvent.tapCreate`.

MacTextInserter now receives a `TextEventPosting` dependency and a Secure Input
probe. Tests exercise Unicode insertion through a fake poster without creating
or posting any `CGEvent`.

A deliberate real development tap test must include both:

```text
--allow-global-input-test
--global-input-test-timeout-seconds 1...30
```

The timeout terminates the process. The immediate manual kill path is:

```sh
/usr/bin/pkill -x wordhand
/usr/bin/pgrep -x wordhand
```

No output from the second command means no exact-name process remains.

## Isolated verification

Command:

```sh
/usr/bin/swift test -Xswiftc -warnings-as-errors
```

Observed:

```text
Test run with 70 tests in 12 suites passed after 0.018 seconds.
```

The new adapter tests were explicitly observed:

```text
hotkeyMonitorUsesInjectedTapAndStopsItWithoutInstallingAGlobalTap passed
textInserterUsesInjectedPosterWithoutPostingSyntheticEvents passed
safeModeBlocksGlobalInputBeforeRuntimeSetup passed
developmentGlobalInputTestRequiresOptInAndBoundedTimeout passed
```

Safe-mode executable check:

```sh
WORDHAND_SAFE=1 .build/debug/wordhand run
```

Observed exit code `1` before runtime setup:

```text
global input disabled because WORDHAND_SAFE is set
no event tap or text injector was installed
```

The release build completed successfully with warnings treated as errors in
3.42 seconds. A final exact-name process check returned no Wordhand process.
