# Application hardening receipt

> Historical receipt only. The live commands below predate the current
> global-input safety rule and must not be rerun unattended. See
> `2026-07-28-global-input-safety.md`.

Date: 2026-07-28
Machine: Aaron's Apple silicon Mac

## Shipped behavior

- Wordhand takes an advisory process lock in its local data directory before
  loading settings or the Whisper model. A second process exits with a useful
  message instead of registering another microphone and global shortcut owner.
- Toggle recording has a 10-minute deadline. Reaching it stops capture and
  processes the recorded audio rather than retaining samples indefinitely.
- Cancel during active transcription signals WhisperKit through its supported
  progress callback and invalidates the coordinator operation before insertion.
- Local AI rewrites now fall back to deterministic cleanup if they lose a
  digit-bearing value, acronym, technical token, or negated constraint.

## Automated gates

Command:

```text
swift test -Xswiftc -warnings-as-errors
```

Observed:

```text
Test run with 58 tests in 11 suites passed
```

Command:

```text
swift build -c release -Xswiftc -warnings-as-errors
```

Observed:

```text
Build complete!
```

Command:

```text
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Observed: exit 0 and `Build complete!`.

Command:

```text
swift test --sanitize=thread --scratch-path /tmp/wordhand-test-tsan-final
```

Observed:

```text
Test run with 58 tests in 11 suites passed
```

Command:

```text
swift build --sanitize=address --scratch-path /tmp/wordhand-app-asan-final
/tmp/wordhand-app-asan-final/debug/wordhand models list
```

Observed: exit 0, no Address Sanitizer report, and all four registered models
were listed.

`swift test --sanitize=address` was also attempted. The generated Swift Testing
registration globals triggered a global-buffer-overflow report before a test
body ran. The reported symbols were generated `$testContentRecord` globals in
the test object file, not Wordhand runtime code. This is recorded as an
unresolved Swift Testing and Address Sanitizer interoperability limitation. The
instrumented Wordhand executable itself built and ran successfully as shown
above.

## Live runtime receipts

Start the rebuilt application:

```text
.build/debug/wordhand run --skip-doctor --dump-wav
```

Observed:

```text
loading whisper-large-v3...
✓ whisper-large-v3 ready
listening on ⌃⌥Z tap · model: whisper-large-v3 · ^C to quit
```

While that process remained live, run the same command again.

Observed:

```text
Error: Wordhand is already running. Open it from the Dock or menu bar.
```

The second process exited 1 before model warmup. The first process remained
responsive.

The final checkpoint media were then driven from the running app:

- choose `Settings…` from the Wordhand menu item; the real Settings window
  opened and showed Large v3, paste insertion, and Automatic writing style;
- move the pointer to the other display and tap `⌃⌥Z`; the recording capsule
  moved to that display and its waveform reacted to live audio;
- send `SIGINT` while recording; the process printed `shutting down` and exited
  without transcribing or inserting the capture.

The final app was relaunched after the media capture and left running.

## Review finding fixed before landing

The first implementation let the recording-limit task cancel itself when it
called the normal release path. That could have canceled the capture tail or
transcription launched by the safety stop. The task now clears its stored
handle before release, and the test asserts that limit-triggered transcription
does not inherit cancellation.

## Honest boundary

This receipt does not claim that software is literally flawless. It proves the
new bounded failure paths, strict builds, sanitizer gates, duplicate-process
behavior, and available live UI behavior. The ten-minute deadline was exercised
with an injected clock rather than a literal ten-minute microphone wait, and a
long-running live Whisper cancellation soak remains open.
