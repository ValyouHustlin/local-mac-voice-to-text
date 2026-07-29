# Installation, permission, and Spotlight repair — 2026-07-29

## Defects reproduced

The installed app was under `~/Applications/Wordhand.app`. Five rollback
bundles with the same bundle identifier also remained in that searchable
Applications directory. LaunchServices reported multiple Wordhand code hashes,
and this command returned no Wordhand result:

```text
/usr/bin/mdfind 'kMDItemCFBundleIdentifier == "com.valyou.wordhand"'
```

The running app reported Accessibility as granted but an attended 30-second
event-tap diagnostic received zero keyboard events. Source inspection then
confirmed that Wordhand did not inspect or expose macOS Input Monitoring at all.
The old two-permission UI could therefore report ready while the global shortcut
listener received no events.

## Changes exercised

`WordhandPermissionStatus`, the Settings permission card, startup recovery,
`doctor`, and `setup` now independently model:

1. Accessibility for cursor insertion;
2. Input Monitoring for the global shortcut;
3. Microphone for audio capture.

The event-tap installer refuses startup with a specific Input Monitoring error
instead of creating a listener that receives nothing. It no longer opens the
Accessibility prompt on every launch. Refreshing permissions also stops a live
monitor if its global-input grants were revoked.

`scripts/install-app.sh` now:

- prefers `/Applications` when it is writable;
- unregisters the previous login item before changing paths;
- preserves active and historical rollback apps under
  `~/Library/Application Support/Wordhand/App Backups`;
- removes old rollback bundles from `~/Applications`;
- explicitly registers the one active bundle with LaunchServices;
- requests a Spotlight import;
- re-registers native launch at login.

## Automated receipt

Command:

```text
WORDHAND_SAFE=1 /usr/bin/xcrun swift test
```

Observed result:

```text
Test run with 81 tests in 12 suites passed.
```

The new permission-readiness check was first run before implementation and
failed to compile because Input Monitoring did not exist in the product model.
After implementation, the focused macOS adapter suite passed 10 tests.

Release build:

```text
WORDHAND_SAFE=1 /usr/bin/xcrun swift build -c release -Xswiftc -warnings-as-errors
```

Observed result: `Build complete!`

## Installed-app and Spotlight receipt

Install command:

```text
./scripts/install-app.sh --launch-at-login
```

Observed:

- active bundle: `/Applications/Wordhand.app`;
- active process executable:
  `/Applications/Wordhand.app/Contents/MacOS/wordhand`;
- native login registration: `Wordhand will launch when you sign in`;
- no `Wordhand*.app` remained directly in `~/Applications`;
- all previous bundles were preserved under the Application Support backup
  directory;
- `codesign --verify --deep --strict /Applications/Wordhand.app` exited zero.

The installer was then driven through a second upgrade with no legacy
`Wordhand.backup.*.app` files remaining in `~/Applications`. That first
verification attempt exposed an empty-glob failure under Bash strict mode after
the new bundle had been safely copied but before registration. The loop was
fixed to tolerate zero matches, and the exact clean-upgrade command was rerun.
It completed through launch-at-login registration, installation, and relaunch.

The real Spotlight UI was opened, queried for `Wordhand`, and visibly returned
the Wordhand icon plus the running app's Hide, Quit, and About actions. This is
the direct UI receipt for the reported discovery failure; LaunchServices name
resolution also returned `com.valyou.wordhand`.

The running final Settings window visibly showed three distinct permission rows
with separate recovery actions. Because installing a new ad-hoc-signed binary
creates a new macOS privacy identity, the exact final build still requires one
fresh user grant for all three permissions. A Developer ID signed release is
still required to make grants persist reliably across future binary upgrades.

## Live permission and Control-Space receipt

After the user granted the exact `/Applications/Wordhand.app` build,
Accessibility, Input Monitoring, and Microphone all displayed green checks and
the running Settings window stated `Wordhand is ready in every app.`

An attended 10-second development listener then received a controlled lowercase
`z` key-down and key-up:

```text
[debug] type=10 keycode=6 flags=0
[debug] type=11 keycode=6 flags=0
```

Finally, the normal installed app was reopened with TextEdit frontmost. A
controlled Control-Space event started recording, a `173 × 43` Wordhand overlay
window appeared, and a second Control-Space event stopped recording. Four
seconds later:

```text
/usr/bin/pgrep -fl '/Applications/Wordhand.app/Contents/MacOS/wordhand'
20075 /Applications/Wordhand.app/Contents/MacOS/wordhand

TextEdit document text:
ZThank you.
```

`Z` was the deliberate event-listener probe already in the blank test document.
`Thank you.` was newly captured from the live microphone, transcribed, formatted,
and inserted at the TextEdit cursor. This observes the complete installed-app
path from global shortcut through recording, local transcription, and cursor
insertion. No unbounded development process was left running.

Residual: this receipt drove the shortcut through a controlled synthetic
Control-Space event so it could be observed deterministically. The event tap and
complete action path are verified; a physical-key gesture was not separately
instrumented.
