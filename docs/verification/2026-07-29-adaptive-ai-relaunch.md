# Adaptive AI structure and inline relaunch receipt — 2026-07-29

## AI Communication claim

Frontier AI models do not benefit from turning every sentence into a bullet.
The useful transformation is proportional structure without semantic loss:
connected reasoning stays prose, parallel requirements can become bullets,
ordered procedures can become numbered steps, and headings are reserved for a
complex request whose parts are otherwise difficult to find.

Wordhand previously violated this rule after the local rewrite. Any flat result
with at least three sentences was deterministically converted into a bullet
list, regardless of meaning. The sentence-count conversion is removed. The
on-device rewrite instructions now explicitly distinguish prose, parallel
items, sequences, and complex execution requests while forbidding invented
requirements, priorities, deadlines, deliverables, or decisions.

## Real local formatter

These commands use Apple's on-device Foundation Models path and do not record
audio or install a global event tap:

```sh
WORDHAND_SAFE=1 .build/debug/wordhand format \
  'The application is working well. I think accuracy should remain the priority. The only open question is whether latency can improve.' \
  --style aiCommunication \
  --application Terminal
```

Observed output remained connected prose:

```text
The application is working well. I think accuracy should remain the priority. The only open question is whether latency can improve.
```

A multi-constraint request remained a clear request rather than becoming a
mechanical list:

```text
I need you to update the settings page. Keep all processing local. Do not change the hotkey. Add a relaunch button next to the model picker and report the tests you ran.
```

A genuine sequence retained explicit order:

```text
First, download the model. Then, verify the checksum. Finally, relaunch Wordhand.
```

These three receipts prove that three sentences no longer imply three bullets.
They do not claim that every possible dictation shape has been classified.

## Inline relaunch

`SettingsController` now compares the persisted model choice with the model
actually loaded by the running process. The model card shows Relaunch Wordhand
only while those values differ. Changing back to the active model removes the
action. Clicking it schedules the same signed bundle to reopen after the current
process releases its lock, then terminates the old process cleanly.

The failing-first controller check exercised:

```text
active model -> no relaunch
choose a different valid model -> relaunch required
invoke relaunch -> injected callback called once
restore the active model -> no relaunch
```

The focused checks passed:

```sh
/usr/bin/swift test --filter agentStructureDoesNotForceOrdinaryProseIntoBullets
/usr/bin/swift test --filter aiCommunicationPreservesProseWhenTheSourceIsNotAList
/usr/bin/swift test --filter modelChangeExposesInlineRelaunchUntilTheActiveModelIsRestored
```

Complete gates:

```sh
/usr/bin/swift test -Xswiftc -warnings-as-errors
# Test run with 113 tests in 14 suites passed after 0.219 seconds.

/usr/bin/swift build -c release -Xswiftc -warnings-as-errors
# Build complete! (4.97s)

/usr/bin/swift test --sanitize=thread
# Test run with 113 tests in 14 suites passed after 0.867 seconds.
```

## Residual UI gate

The inline button and restart scheduler are adapter-tested, but the button has
not been clicked in Aaron's live app during active work. That deliberate live
click remains the final visual and process-lifecycle receipt.
