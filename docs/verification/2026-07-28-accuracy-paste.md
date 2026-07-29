# Accuracy, capture, hotkey, and paste receipt — 2026-07-28

This report records only behavior observed on Aaron's Mac in this session.
Spoken test phrases were played through `/usr/bin/say` and captured by the
default HyperX QuadCast desk microphone. They are controlled microphone
receipts, not proof of accuracy on Aaron's natural voice.

## Model benchmark

Fixture:

```text
.build/checkouts/WhisperKit/Tests/WhisperKitTests/Resources/jfk.wav
```

Commands:

```sh
.build/debug/wordhand models benchmark \
  .build/checkouts/WhisperKit/Tests/WhisperKitTests/Resources/jfk.wav \
  --model whisper-base.en

.build/debug/wordhand models benchmark \
  .build/checkouts/WhisperKit/Tests/WhisperKitTests/Resources/jfk.wav \
  --model whisper-large-v3
```

Observed results:

| Model | Audio | Warmup | Transcription | Real-time factor | Output |
| --- | ---: | ---: | ---: | ---: | --- |
| Base English | 11.00s | 7.669s | 0.742s | 0.067x | Correct reference sentence |
| Optimized Large v3 626 MB | 11.00s | 46.297s | 1.025s | 0.093x | Correct reference sentence, with an additional comma after “And so” |

Warmup happens before the shortcut becomes active. Large v3 was then selected
in `~/Library/Application Support/Wordhand/settings.json`, the app was
relaunched, and stderr reported:

```text
✓ whisper-large-v3 ready
listening on ⌃⌥Z tap · model: whisper-large-v3
```

## Native target and hotkey suppression

Initial gesture: create a new TextEdit document, tap Control-Option-Z, play a
test phrase, tap Control-Option-Z again.

The first receipt exposed two `0x1a` bytes before the transcript. Source
inspection confirmed that the global event tap used `.listenOnly`, so the
configured shortcut reached the target app.

After switching to an active event tap and consuming only configured shortcut
key edges, the same flow produced a TextEdit document whose first byte was the
first transcript byte. No shortcut bytes appeared. The 7.59-second capture
transcribed in 1.06 seconds and retained the final spoken word `complete`.

The temporary TextEdit documents were closed without saving.

## Browser target and clipboard restoration

Setup:

- create a fresh Google Chrome window at `https://www.google.com/`;
- preload the general pasteboard with one item containing
  `public.rtf`, `public.utf8-plain-text`, and
  `public.utf16-external-plain-text`;
- use the sentinel text `WORDHAND_CLIPBOARD_SENTINEL`;
- leave Google Search focused;
- tap Control-Option-Z, play the phrase, and tap again.

Observed:

```text
○ captured 5.39s · rms 0.018
→ 0.76s · Chrome paste insertion ends with the final word complete.
```

The complete sentence was visibly present in the Google Search field. A
post-insertion pasteboard read returned the original sentinel, all three
original types, and non-nil RTF data. The temporary Chrome window was closed.

## Electron target and clipboard restoration

Target: Visual Studio Code 1.127.0, an Electron 42.2.0 application.

Setup:

- select a new unsaved `Untitled-2` plain-text tab;
- preload an RTF plus plain-text clipboard item containing
  `WORDHAND_ELECTRON_CLIPBOARD`;
- focus line 1;
- tap Control-Option-Z, play the phrase, and tap again.

Observed:

```text
○ captured 5.39s · rms 0.019
→ 0.76s · Electron paste insertion ends with the final word complete.
```

The complete sentence was visibly present on line 1. A pasteboard read returned
the original sentinel, all three original types, and non-nil RTF data. The
scratch tab was closed with `Don't Save`.

During target setup, one earlier attempt focused an existing VS Code file
instead of the scratch tab. The verification sentence appeared at its first
line; Command-Z was immediately issued and a screenshot confirmed the original
heading was restored before the safe scratch-tab receipt proceeded.

## Automated boundary

Covered:

- recommended model identity;
- async capture/coordinator flow;
- live insertion-mode updates;
- shortcut consumption for matched key-down, repeat, and key-up events while
  preserving unrelated keys;
- pasteboard ownership rule: restore when Wordhand still owns the pasteboard,
  preserve a newer external clipboard write.

Not yet covered by an adapter-level automated test:

- AppKit serialization of every pasteboard type;
- a forced `IsSecureEventInputEnabled()` live field;
- clipboard write/event-construction failure;
- immediate undo/revert of the last insertion.

Final commands:

```sh
/usr/bin/git diff --check
/usr/bin/xcrun swift test
/usr/bin/xcrun swift build -c release
```

Observed final output:

```text
Test run with 45 tests in 10 suites passed after 0.021 seconds.
Build complete! (4.70s)
```

The final debug binary was relaunched after those source changes. It loaded
Large v3, announced the configured Control-Option-Z toggle binding, and opened
the Settings window from its Dock icon. The visible controls showed
`Whisper Large v3 (Accuracy) · 626 MB` and `Paste · Recommended`.
