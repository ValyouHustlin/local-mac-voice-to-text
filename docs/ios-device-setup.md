# iPhone 17 Pro build and setup

## Current machine blocker

As observed on 2026-07-28, this Mac has Command Line Tools but no full Xcode,
iOS SDK, simulator manager, or device manager. Install full Xcode before using
this project. That installation is not part of this branch.

## Open and configure

1. Open `Mobile/WordhandMobile.xcodeproj` in a current full Xcode.
2. Let Swift Package Manager resolve the local Wordhand package and WhisperKit.
3. Select a development team for both `WordhandMobile` and
   `WordhandKeyboard`.
4. Register or adjust these identifiers in the selected team:
   - `com.valyou.wordhand`
   - `com.valyou.wordhand.keyboard`
   - `group.com.valyou.wordhand`
5. Keep the same App Group enabled for both targets.
6. Connect and trust Aaron's iPhone 17 Pro, then select it as the run
   destination.

Selecting a team, changing identifiers, or creating certificates is an
Aaron-gated decision. The project deliberately leaves `DEVELOPMENT_TEAM`
empty.

## Install the keyboard

After the app launches once:

1. Open Settings > General > Keyboard > Keyboards > Add New Keyboard.
2. Choose Wordhand Keyboard.
3. Enable Full Access. Apple gates the local App Group handoff behind this
   switch even though Wordhand does not use network access.
4. Grant Microphone and Speech Recognition permissions when the containing app
   asks.

## Required device receipt

Run:

```text
xcodebuild -project Mobile/WordhandMobile.xcodeproj \
  -scheme WordhandMobile \
  -destination 'platform=iOS,name=<Aaron iPhone name>' \
  build
```

Then dictate the fixed benchmark corpus once through Apple Speech and once
through Whisper Large. Use Instruments to record peak resident memory and
Energy/thermal behavior. Finally drive the keyboard flow in Messages, Notes,
and ChatGPT. Record exact gestures, visible text, post-stop latency, whether
Record opened the host app, and how return-to-origin behaved.

WhisperKit may access the network only after the explicit 626 MB engine
selection and only to obtain model assets. Re-run inference with networking
disabled before claiming the engine works fully offline.
