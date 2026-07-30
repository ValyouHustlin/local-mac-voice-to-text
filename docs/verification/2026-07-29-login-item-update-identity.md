# Login-item update identity — 2026-07-29

## User-observed symptom

Aaron received repeated macOS approval prompts naming `sfltool` after Wordhand
app updates. He had not installed unrelated persistence. The prompts followed
the development update loop.

## Confirmed repository cause

The previous development command was:

```sh
./scripts/install-app.sh --launch-at-login
```

Source inspection confirmed that every invocation:

1. ran `wordhand install --uninstall` from the previous bundle;
2. replaced the application;
3. ran `wordhand install --launch-at-login` from the new bundle.

The app command used `SMAppService.mainApp` for an application bundle and
retained a LaunchAgent fallback for command-line builds. Development and
release also shared `com.valyou.wordhand`.

This was an update-path product defect. Re-registering persistence during
routine updates makes macOS Background Task Management re-evaluate the item and
can produce a new approval prompt.

Apple's Service Management documentation confirms the lifecycle that matters
here: `register()` registers the main app to launch on subsequent logins
subject to user approval, while `unregister()` removes that registration.
Apple does not document the exact `sfltool` prompt observed on this machine, so
the prompt linkage remains a user-observed receipt plus the confirmed
unregister/register loop rather than an Apple-documented guarantee:

- <https://developer.apple.com/documentation/servicemanagement/smappservice/register()>
- <https://developer.apple.com/documentation/servicemanagement/smappservice/unregister()>

## Repair

- Development is now the default build channel:
  `Wordhand Dev.app` / `com.valyou.wordhand.dev`.
- The canonical `Wordhand.app` / `com.valyou.wordhand` identity is reserved for
  a release signed by a `Developer ID Application` identity.
- The development installer rejects `--launch-at-login` before building.
- Development and command-line app code cannot register a login item.
- The legacy LaunchAgent creation path was removed.
- Only the signed release app can expose `SMAppService.mainApp`.
- The release installer no longer unregisters and re-registers login launch as
  part of replacement. Launch at login is a deliberate Settings action.
- CI runs the persistence and unsigned-release guards on every change.

## Immediate machine cleanup

Command:

```sh
/Applications/Wordhand.app/Contents/MacOS/wordhand install --uninstall
```

Observed:

```text
✓ launch-at-login removed
```

Follow-up checks observed no `com.valyou.wordhand` launchd service and neither
`~/Library/LaunchAgents/com.valyou.wordhand.plist` nor
`~/Library/LaunchAgents/com.digimata.parrot.plist`.

The read-only Background Task Management inventory also returned no Wordhand
entry:

```sh
/usr/bin/sfltool dumpbtm | rg -i 'wordhand|com\.valyou\.wordhand'
```

Observed: no output.

The already-running build 13 app was left open so Aaron's active work and
current privacy grants were not interrupted. It is no longer registered to
start at login.

## Guard receipts

Development installer:

```sh
./scripts/install-app.sh --launch-at-login
```

Observed exit 78:

```text
installers never register a login item during updates
signed releases expose launch at login in Wordhand Settings
```

Unsigned/local-certificate release attempt:

```sh
WORDHAND_BUILD_CHANNEL=release ./scripts/build-app.sh
```

Observed exit 78:

```text
release builds require an explicit Developer ID Application identity
development builds must use the default development channel
```

Development build:

```sh
WORDHAND_BUILD_NUMBER=14 ./scripts/build-app.sh
```

Observed:

```text
Built .../dist/Wordhand Dev.app
Channel: development
Bundle identifier: com.valyou.wordhand.dev
Signature: Wordhand Local Signing
```

The designated code requirement used the development identifier and the same
stable local certificate hash as the prior local builds.

The built development binary was also asked to register launch at login:

```sh
dist/Wordhand\ Dev.app/Contents/MacOS/wordhand install --launch-at-login
```

Observed exit 78:

```text
Launch at login is disabled for development and command-line builds.
Install a signed release app, then enable it from Wordhand Settings.
```

No LaunchAgent or launchd service appeared afterward.

Automated commands:

```sh
/bin/bash scripts/test-packaging-guards.sh
WORDHAND_SAFE=1 /usr/bin/swift test
```

Observed:

```text
✓ development login-item registration is blocked
✓ unsigned release identity is blocked
Test run with 127 tests in 15 suites passed
Build complete! (7.03s)
```

## Open release gate

No Developer ID Application certificate or notarized update artifact was
available in this lane, and selecting one requires Aaron's approval. Therefore
the final shipping receipt remains open: install a notarized release, enable
launch at login once, apply an update with the same path, bundle identifier,
and signing identity, and observe that macOS produces no Background Items,
Microphone, Input Monitoring, or Accessibility prompt.

The current development app was not replaced with the new development identity
while Aaron was working because that one-time identity migration would require
fresh privacy grants. The next attended development install must make that
migration explicitly.
