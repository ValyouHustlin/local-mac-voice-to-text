# Settings and configurable hotkeys receipt

Date: 2026-07-28  
Build: local debug build  
Data: isolated temporary directory, deleted after verification

## Automated checks

Command:

```text
/usr/bin/xcrun swift test
```

Observed result:

```text
Test run with 41 tests in 9 suites passed
```

The new coverage exercises tap-to-toggle edges, repeated key events, multiple
bindings, cross-release rejection, settings changes during recording, missed
modifier release, legacy settings decoding, bare shortcut rejection, and
duplicate shortcut rejection. This is behavioral coverage of the pure routing
and persistence logic, not a percentage coverage claim.

## Native Settings window

Gesture:

1. Click the Wordhand menu bar icon.
2. Click `Settings…`.

Observed result:

- A native Settings window opened and became key.
- The window showed the current shortcut, recording behavior, add/remove
  controls, recording-indicator toggle, and local-processing promise.
- Closing and reopening the window preserved the saved controls.

## Behavior change without restart

Gesture:

1. Open Settings.
2. Change `Hold to talk` to `Tap to start, tap to stop`.
3. Click the shortcut recorder.
4. Press Control-Option-D.

Observed result:

- `settings.json` was written atomically with key code `2`, modifiers
  `control` and `option`, and action `toggleRecording`.
- The menu changed immediately to `idle · tap ⌃⌥D to dictate`.
- The process was not restarted.

## Live toggle and rebind

Gesture:

1. Close Settings.
2. Tap Control-Option-D once and release it.
3. Open the menu after the key was released.
4. Close the menu and tap Control-Option-D again.
5. Tap the previous Control-Space shortcut.

Observed result:

- After step 2, the menu still read `● recording`, proving recording was not
  tied to the physical key hold.
- The second tap ended capture. The app reported a 1.59 second local capture
  and completed local transcription in 0.12 seconds.
- Control-Space did not start recording after rebinding. The menu remained
  `idle · tap ⌃⌥D to dictate`.
- After quitting and starting the app again with the same data directory, the
  process reported `listening on ⌃⌥D tap`, proving the binding and behavior
  survived restart.
- The temporary history and settings directory used for this receipt was
  deleted after the test.

## Open exit-gate work

- Dictate through the rebound shortcut into a native app, browser field, and
  Electron app.
- Sleep/wake recovery remains unverified.
