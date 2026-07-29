# Daily-driver application receipt — 2026-07-28

Scope: local application packaging, launch at login, startup readiness,
permissions recovery, offline cached-model startup, and local-data permissions.

## Automated gates

Command:

```sh
/usr/bin/swift test -Xswiftc -warnings-as-errors
```

Observed:

```text
Test run with 74 tests in 12 suites passed
```

Command:

```sh
./scripts/build-app.sh
```

Observed:

```text
Built .../dist/Wordhand.app
Version 0.1.0 (1)
Signature: local ad hoc
```

`codesign --verify --deep --strict` completed successfully inside the build
script. This proves bundle integrity for the local build; it is not Developer
ID signing or notarization.

## Installed behavior

Command:

```sh
./scripts/install-app.sh --launch-at-login
```

Observed:

- installed at `~/Applications/Wordhand.app`;
- preserved the previous installed app as a timestamped rollback copy;
- the bundled `wordhand install --launch-at-login` command reported that
  Wordhand will launch after sign-in;
- the running process path resolved inside the installed application bundle,
  whose bundle identifier is `com.valyou.wordhand`.

Command:

```sh
~/Applications/Wordhand.app/Contents/MacOS/wordhand doctor
```

Observed:

```text
microphone: ok
accessibility: ok
Control-Space: ok
```

This shell-launched diagnostic inherited a permission context that did not
match the LaunchServices-opened app. Visual inspection of the running app's
Permissions card showed Accessibility unavailable and Microphone not yet
requested for the installed bundle. The in-app state is authoritative: Aaron
must grant both once through macOS before the bundled hotkey and microphone can
be called ready. This slice does not claim those grants are complete.

On a launch from the installed bundle, the menu/Dock application and configured
interface became available before model loading completed. In an attended
installed-bundle run after the shell permission check, the runtime reported:

```text
listening on ⌃Space tap · model: whisper-large-v3
loading whisper-large-v3...
using cached local model; network disabled
✓ whisper-large-v3 ready in 1.53s
```

This was an attended installed-bundle run using
`--allow-global-input-test --global-input-test-timeout-seconds 30`; it exited
automatically at the bound. The timing is a warm-cache measurement on Aaron's
M5 Max, not a cold boot or a first model load.

The installed application opened its Settings window through AppKit. The
Permissions card exposed current Microphone and Accessibility state; recovery
behavior is additionally covered through a fake permission manager so tests do
not alter system privacy settings.

The live Wordhand data directory was observed with mode `0700`. `settings.json`,
`dictionary.json`, `history.sqlite`, and its SQLite sidecar files were observed
with mode `0600` after the final installed launch.

## Not exercised in this slice

- Developer ID signing, hardened runtime, notarization, or a public installer;
- a clean macOS user account and first-ever model download;
- the one-time app-bundle Microphone and Accessibility approvals remain for
  Aaron to grant through the visible macOS controls;
- a physical Dock click was not observed in this slice; the optimized-build
  delegate lifetime bug found while probing reopen behavior was fixed, but the
  automated Dock accessibility action did not activate the app and is not
  treated as proof of a physical click;
- dictation across native, browser, and Electron targets was not repeated in
  this packaging slice; earlier dated receipts cover those feature paths.
