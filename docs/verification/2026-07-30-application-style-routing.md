# Application-specific writing style routing — 2026-07-30

## Outcome

Wordhand keeps one global Writing Style and can optionally assign any of the
same four styles to an exact macOS application bundle identifier. The setting
is local, immediately persisted, and removable. It does not infer from display
names, app categories, or surrounding text.

One immutable processing context is captured when an accepted dictation begins:
target application, resolved style, route source, and performance mode. The
same context drives formatter prewarming, transcript processing, History target
provenance, and private lifecycle diagnostics. Switching applications or
editing Settings during speech therefore changes only the next dictation.
Crash recovery has no trustworthy target and uses the global default.

## Deterministic evidence

The focused gate passed 57 tests across `SettingsTests`,
`DictationCoordinatorTests`, and `GlobalInputAdapterTests`. It covered:

- exact case-insensitive bundle-ID matching and display-name non-matching;
- legacy settings decode, atomic persistence, validation, removal, the 24-rule
  bound, and duplicate-rule fail-safe fallback that preserves every unrelated
  saved preference without overwriting the original file;
- one target lookup per dictation and immutable routing despite a mid-dictation
  Settings change;
- identical captured context for prewarm, formatting, History, and diagnostic
  route/profile fields;
- live processor updates applying to the next target while unrelated apps keep
  the global default.

Command:

```sh
WORDHAND_SAFE=1 swift test \
  --filter SettingsTests \
  --filter DictationCoordinatorTests \
  --filter GlobalInputAdapterTests
```

Result: 57 tests in 3 suites passed in 1.487 seconds on 2026-07-30.

The complete safe gate then passed 269 tests across 30 suites in 2.268
seconds. The release build passed with warnings treated as errors, and both
packaging guards passed:

```sh
WORDHAND_SAFE=1 swift build -c release -Xswiftc -warnings-as-errors
WORDHAND_SAFE=1 ./scripts/test-packaging-guards.sh
```

## Native UI observation

The opt-in AppKit render test drove the real Settings controller and view with
a Terminal override and TextEdit available to add:

```sh
WORDHAND_SAFE=1 \
WORDHAND_SETTINGS_RENDER_RECEIPT=1 \
WORDHAND_SETTINGS_RENDER_OUTPUT=/tmp/wordhand-app-routing-settings.png \
swift test --filter rendersAppSpecificWritingStyleWithoutHidingGlobalDefault
```

Observed output: a 900×1500 inspection render of the native Settings view with the
global picker first, an explicitly optional App-specific styles section, a
Terminal row showing `com.apple.Terminal`, its AI Communication picker and
remove action, and one compact “Use a different style in TextEdit” menu. No
clipping, overlap, hidden default, or unexplained control was visible at that
inspection size. The existing resizable/scrollable 760×620 default window was
not separately captured for this receipt.

## Safety and residual boundary

No microphone, clipboard, global event tap, synthetic input, installed-app
replacement, or process restart was used. `/Applications/Wordhand Dev.app`
build 22 remained running as PID 7994. The installed daily-runtime flow has not
been exercised with natural dictation; that attended boundary remains explicit.
