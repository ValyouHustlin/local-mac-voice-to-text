# iPhone foundation verification, 2026-07-28

## Outcome

The pure mobile handoff and local-observation boundary builds and passes tests
on macOS. The iOS host app and keyboard project exist, and all plist,
entitlement, project, scheme, and Swift source files pass syntax-level checks.
No iOS runtime claim is made because full Xcode, an iOS SDK, and a discoverable
iPhone were absent.

## Toolchain discovery

Commands and observed output:

```text
$ xcode-select -p
/Library/Developer/CommandLineTools

$ xcrun xcodebuild -version
xcrun: error: unable to find utility "xcodebuild", not a developer tool or in PATH

$ xcrun --sdk iphoneos --show-sdk-path
xcrun: error: SDK "iphoneos" cannot be located

$ xcrun simctl list devices available
xcrun: error: unable to find utility "simctl", not a developer tool or in PATH

$ xcrun devicectl list devices
xcrun: error: unable to find utility "devicectl", not a developer tool or in PATH
```

`system_profiler SPUSBDataType` and `ioreg -p IOUSB` returned no iPhone or Apple
mobile-device match during this session.

## Executed checks

```text
$ swift test
Build complete! (2.92s)
Test run with 47 tests in 10 suites passed after 0.022 seconds.
```

The six new mobile tests observed:

- shared transcript processing and persistence;
- exact-once consumption;
- stale-consumer protection for a newer draft;
- expired-draft purge;
- empty-result recovery;
- private local benchmark-observation persistence.

The run count is 47 because the fixture contains six mobile tests in addition
to the previous 41 desktop-core tests.

```text
$ swiftc -frontend -parse Mobile/WordhandMobile/*.swift \
    Mobile/WordhandKeyboard/*.swift Mobile/Shared/*.swift
```

Exit status: 0, with no output.

```text
$ plutil -lint Mobile/WordhandMobile/Info.plist \
    Mobile/WordhandMobile/WordhandMobile.entitlements \
    Mobile/WordhandKeyboard/Info.plist \
    Mobile/WordhandKeyboard/WordhandKeyboard.entitlements \
    Mobile/WordhandMobile.xcodeproj/project.pbxproj
```

Each file returned `OK`. An Xcode scheme is XML but not a property list, so
`xmllint --noout` was used for the scheme and exited 0 with no output.

```text
$ swift package describe
```

Exit status: 0. The output listed the `WordhandMobileCore` library and
`WordhandMobileCoreTests` target.

```text
$ swift build -c release
Build complete! (56.84s)
```

## Not verified

- semantic compilation against UIKit, Speech, or an iOS SDK;
- Xcode project package resolution;
- automatic or manual signing;
- App Group availability on device;
- host-app recording;
- Apple on-device Speech result;
- WhisperKit model download or inference;
- keyboard request to open the host app;
- return to the originating app;
- cursor insertion in Messages, Notes, or ChatGPT;
- accuracy, latency, peak memory, battery, or thermal behavior.

These are blocked on a full Xcode installation, provisioning-team choice, and a
connected iPhone 17 Pro. The exact continuation is in
`docs/ios-device-setup.md`.
