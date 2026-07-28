# Foundation verification receipt

Date: 2026-07-28

Commit: pending at time of first write.

## Automated tests

Command:

```text
/usr/bin/swift test
```

Observed:

```text
Testing Library Version: 6.3.1 (937120cbc281cf2)
Test run with 15 tests in 4 suites passed after 0.002 seconds.
```

The suites cover:

- model registry uniqueness, recommendation, and engine metadata;
- known non-speech token cleanup without deleting legitimate parentheses,
  brackets, or emphasis;
- dictionary precedence, non-cascading replacement, and Unicode word
  boundaries;
- settings defaults, validation, missing-file behavior, directory creation,
  atomic save, and load round-trip;
- successful dictation coordination, duplicate press suppression, empty audio,
  insertion failure visibility, and retry after failure.

Coverage percentage was not measured. The suite covers new pure logic and
coordinator branches, not AVFoundation, WhisperKit, CoreGraphics, AppKit, or
TCC behavior.

The Mac has standalone Command Line Tools 26.4.1 rather than full Xcode. That
installation omits XCTest and misroutes its bundled Testing framework. The
package therefore pins the official `swift-testing` source release matching the
installed Swift 6.3.1 toolchain. A narrow conditional linker path is used only
when the manifest detects Command Line Tools without Xcode.

## Release build

Command:

```text
/usr/bin/swift build -c release
```

Observed:

```text
Build complete! (3.96s)
```

## Live daemon launch

Command:

```text
.build/debug/parrot run --skip-doctor --no-overlay
```

Observed:

```text
loading whisper-base.en...
✓ whisper-base.en ready
listening on fn hold · model: whisper-base.en · ^C to quit
^C
shutting down
```

This proves the rebuilt executable reaches its live ready state and exits
cleanly. A second ambient microphone run was deliberately not performed after
the baseline captured unrelated room speech.

## Review

First-pass diff review result: no blocking findings after moving the recording
log onto the actual state transition and pinning the CI toolchain to Swift
6.3.1.

Residual runtime risks:

- direct Unicode insertion still cannot acknowledge that the target accepted
  text;
- event-tap re-enablement, secure input, paste, history, dictionary UI, and
  configurable hotkeys remain later phases;
- browser end-to-end insertion remains unverified;
- CI is configured but its first remote run is pending the foundation push.
