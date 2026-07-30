# Resizable Settings and stable local signing path — 2026-07-29

## Permission-reset diagnosis

The installed `/Applications/Wordhand.app` was inspected with:

```sh
/usr/bin/codesign -d -r- /Applications/Wordhand.app
/usr/bin/codesign -dv --verbose=4 /Applications/Wordhand.app
```

Observed:

```text
# designated => cdhash H"2e9a4f4cbabcc72a9c87d892b0461648b4677ad7"
Identifier=com.valyou.wordhand
Signature=adhoc
TeamIdentifier=not set
```

The candidate rebuilt bundle was inspected at
`/tmp/wordhand-settings-build/Wordhand.app`. It kept the same bundle identifier
but had a different designated code hash:

```text
# designated => cdhash H"dc5b55ec3d23707957bdea819513ffcf53272404"
Identifier=com.valyou.wordhand
Signature=adhoc
TeamIdentifier=not set
```

This is the concrete reason privacy grants can fail to carry across local
updates: the current app is ad-hoc signed and its designated identity changes
with the binary.

## Changes

- Settings now has the native resizable window style.
- The initial content size is 760 by 620 points.
- The minimum window size is 620 by 440 points.
- Settings content expands horizontally with the window and remains vertically
  scrollable.
- AppKit frame autosave uses the stable name `Wordhand.Settings`.
- `scripts/build-app.sh` now reads a persistent identity display name from
  `~/Library/Application Support/Wordhand/signing-identity`, while an explicit
  `WORDHAND_CODESIGN_IDENTITY` remains the highest-priority override.
- Ad-hoc builds print a permission-reset warning instead of presenting their
  signature as harmless.
- `scripts/configure-local-signing.sh` validates that the chosen identity exists
  in Keychain before saving its display name with owner-only permissions. It
  never stores or exports the private key.

After Aaron explicitly authorized the certificate action, a
`Wordhand Local Signing` identity was created in the login Keychain and selected
through `scripts/configure-local-signing.sh`. Keychain reports one valid code
signing identity. The persisted identity-name file is owner-only `0600`; the
private key remains in Keychain.

## Verification

Shell validation:

```sh
/bin/bash -n scripts/build-app.sh scripts/configure-local-signing.sh scripts/install-app.sh
```

The configuration helper returned status 64 with no identity and status 1 for a
nonexistent identity, without writing a configuration.

The real AppKit window constructor was exercised by
`settingsWindowIsResizableAndCanShowMoreContent`. It observed the resizable
style, the 760 by 620 default, the 620 by 440 minimum, and successfully changed
the content area to 900 by 700 points. Closing and rebuilding the controller
restored the exact 900 by 700 content size from an isolated per-test autosave
key. The complete suite also observed that Aaron's real Settings frame was
unchanged before and after the run.

```sh
/usr/bin/swift test
```

Observed result:

```text
Test run with 109 tests in 14 suites passed
```

The release application build was driven without replacing the installed app:

```sh
WORDHAND_APP_OUTPUT=/tmp/wordhand-settings-build/Wordhand.app \
WORDHAND_SIGNING_CONFIG=/tmp/wordhand-no-signing-config \
scripts/build-app.sh
```

Observed result:

```text
Build complete!
Built /tmp/wordhand-settings-build/Wordhand.app
Signature: local ad hoc
Warning: macOS permissions may reset when this build replaces a previous ad-hoc build.
Configure one stable Keychain identity with scripts/configure-local-signing.sh.
```

## Installed update receipt

The app was then installed repeatedly with different build numbers so the test
used genuinely different signed bundles. The first signed build reported:

```text
Authority=Wordhand Local Signing
CDHash=accb20ef16dca17b8af8fc94247beeadf0ccf859
```

Build 2 reported:

```text
Authority=Wordhand Local Signing
CDHash=680e6f6f98eb17329dfe3abf61616759e8513e44
```

Build 5, the final installed product build, reported:

```text
Authority=Wordhand Local Signing
CDHash=d05e286719361cd88444ffe3cb5e611a3043a740
```

Despite the changed code hashes, every post-install doctor run observed:

```text
✓ microphone: ok
✓ accessibility: ok
✓ input monitoring: ok
✓ Control-Space: ok
```

The designated requirement is now stable:

```text
identifier "com.valyou.wordhand" and certificate root =
H"2bdc70941494fdbfb7453585b23ae93c67baaa5e"
```

No audio or dictation test was performed.

## Live Settings receipt

The installed Settings window was resized through macOS Accessibility from 620
by 440 to 900 by 700 points, then closed. The app stored:

```text
410 1307 900 700 0 0 1440 2530
```

After terminating and reopening Wordhand, the real window reported:

```text
270, 488, 900, 700
```

The changed position is macOS keeping the larger frame on-screen; the requested
900 by 700 size survived the complete process restart.
