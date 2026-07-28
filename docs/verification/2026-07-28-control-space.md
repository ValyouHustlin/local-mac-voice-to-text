# Control-Space shortcut verification — 2026-07-28

## Scope

This receipt covers the fixed Control-Space push-to-talk default, its pure edge
logic, the macOS reserved-shortcut check, and launching the actual app with its
Dock icon. It does not claim a physical spoken dictation receipt.

## Automated shortcut behavior

Command:

```text
/usr/bin/swift test
```

Observed:

```text
Test run with 32 tests in 7 suites passed
```

The four shortcut tests observed:

- Control-Space emits exactly one press and one release;
- repeated key-down and key-up events do not duplicate edges;
- Space alone, the wrong key, and extra starting modifiers do not trigger;
- releasing Control before Space emits a recovery release.

## Machine checks

Commands:

```text
/usr/libexec/PlistBuddy -c "Print :AppleSymbolicHotKeys:60" \
  ~/Library/Preferences/com.apple.symbolichotkeys.plist
/usr/libexec/PlistBuddy -c "Print :AppleSymbolicHotKeys:61" \
  ~/Library/Preferences/com.apple.symbolichotkeys.plist
.build/debug/parrot doctor
```

Observed:

```text
symbolic hotkey 60 enabled = false
symbolic hotkey 61 enabled = false
microphone: ok
accessibility: ok
Control-Space: ok
```

Wispr Flow was also observed running. Because it uses Aaron's same preferred
shortcut, it must be quit or snoozed before an isolated Parrot dictation test.
It was not terminated automatically.

## Live application and Dock receipt

Command:

```text
.build/debug/parrot run
```

Observed:

```text
loading whisper-base.en...
whisper-base.en ready
listening on Control-Space hold · model: whisper-base.en
```

The macOS Dock accessibility tree listed a `parrot` tile. Clicking that exact
Dock tile made the process frontmost and opened a visible window named
`Transcript History – Parrot`. The process was left running for Aaron's test.

## Open exit receipt

Quit or snooze Wispr Flow, focus a normal text field, hold Control-Space while
speaking, and release. Record the target app, inserted text, missed edges if
any, and release-to-insertion latency before calling the live shortcut fully
shipped.
