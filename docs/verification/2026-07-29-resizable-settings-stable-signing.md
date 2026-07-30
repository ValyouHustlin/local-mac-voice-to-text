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

No signing identity or certificate was selected in this change. That remains an
explicit owner decision.

## Verification

Shell validation:

```sh
/bin/bash -n scripts/build-app.sh scripts/configure-local-signing.sh scripts/install-app.sh
```

The configuration helper returned status 64 with no identity and status 1 for a
nonexistent identity, without writing a configuration.

The real AppKit window constructor was exercised by
`settingsWindowIsResizableAndCanShowMoreContent`. It observed the resizable
style, the 620 by 440 minimum, and successfully changed the content area to 900
by 700 points.

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

## Residual verification

The candidate was intentionally not installed because doing so with another
ad-hoc identity would cause the exact permission churn this change is meant to
stop. After Aaron authorizes one local certificate choice, install the candidate
with that identity, resize and reopen Settings, then rebuild and confirm
Microphone, Input Monitoring, and Accessibility remain granted.
