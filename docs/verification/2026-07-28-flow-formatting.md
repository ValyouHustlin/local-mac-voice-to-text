# Flow feedback and app-aware formatting receipt — 2026-07-28

> Historical receipt only. The live commands below predate the current
> global-input safety rule and must not be rerun unattended. See
> `2026-07-28-global-input-safety.md`.

## Scope

This receipt covers the recording feedback pass and the first local,
application-aware writing profile. It does not claim that the tones are
subjectively perfect or that every application has a specialized profile.

## Automated checks

Command:

```sh
/usr/bin/swift test
```

Observed result after the cancellation-router fix:

```text
Test run with 52 tests in 10 suites passed
```

The added checks cover:

- cancellation while capturing;
- cancellation while transcription is suspended;
- no insertion after a canceled transcription;
- tap-toggle reset after clicking cancel;
- old settings decoding with new defaults;
- writing-profile persistence and automatic target resolution;
- deterministic filler, casing, punctuation, and dictionary behavior.

## Minimal overlay and cancellation

Launch:

```sh
.build/debug/wordhand run --skip-doctor --dump-wav
```

Gesture:

1. Tap the configured Control-Option-Z toggle.
2. Click the visible X through macOS Accessibility.
3. Tap the shortcut again.

Observed:

- the overlay appeared as a matte capsule with an eleven-bar waveform and
  cancel button;
- a live screenshot during speech showed asymmetric center bars rising strongly
  while the container stayed borderless and visually quiet;
- clicking the button removed the overlay without a capture or transcript log;
- the very next shortcut tap started recording instead of being consumed as a
  stale stop;
- the runtime accepted playback for start and cancel cues:

```text
recording
sound cue: start
sound cue: cancel
recording
sound cue: start
sound cue: cancel
```

The playback API returning success proves the cues were scheduled. Their
subjective loudness and character still require Aaron's ears.

## Display following

The Mac had two active display frames:

```text
(0, 0, 1440, 2560)
(1440, 310, 3360, 1890)
```

While recording, the pointer was moved from the portrait display to the
ultrawide. Accessibility reported the same overlay window at:

```text
portrait:  position (638, 2474), size (173, 43)
ultrawide: position (3033, 2173), size (173, 43)
```

The overlay remained visible and moved to the bottom center of the pointer's
display.

## Local AI-prompt formatting

Target: Ghostty.

Input gesture:

1. Activate Ghostty.
2. Tap Control-Option-Z.
3. Play a 16.99-second spoken fixture through the Mac speakers.
4. Tap Control-Option-Z again.

Whisper Large v3 raw output:

```text
I want the settings window to feel modern and minimal and then make sure the
hotkey works in every application. Also, preserve the user clipboard. Do not
send audio to the cloud and add text for cancellation.
```

Inserted output from the Automatic profile:

```text
Settings window:
- Modern and minimal design
- Hotkey works in every application
- Preserve user clipboard
- No audio sent to the cloud
- Text for cancellation
```

The history record reported:

```text
target_app_name: Ghostty
audio_seconds: 16.99
transcription_seconds: 1.22
insertion_status: inserted
```

A later timing run against the finalized bounded-generation path observed:

```text
captured: 13.90s
Whisper Large v3: 1.08s
local AI formatting: 1.03s
```

Final inserted output:

```text
We need a minimal recording pop-up. Make the waveform react strongly. Keep the
interface quiet. Preserve the clipboard. Add a cancel button that never inserts
discarded text.
```

The timing instrumentation first exposed a 47.46-second Foundation Models
context-budget failure. The formatter now caps response tokens proportionally,
uses deterministic generation, and enforces a four-second deadline before
falling back. Re-running the same 13.90-second fixture produced the 1.03-second
formatting result above.

The spoken fixture said “tests for cancellation”; Whisper produced “text for
cancellation,” and the formatter preserved that model output instead of
silently inventing the missing word. The first live formatter run also exposed
an internal-label echo; the model input was changed to contain only the
transcript, and the receipt above is from the corrected path.

## Settings

Gesture: click the Wordhand Dock icon.

Observed: the running app opened a 680-by-472 Settings window. The new Writing
style card showed Automatic as recommended and described AI/coding app routing.
The lower Recording feedback card contains independent switches for the overlay
and sound cues.

## Residual risk

- A human listening pass is still needed to tune cue timbre and loudness.
- Waveform behavior was visually inspected at the fixture's measured RMS
  `0.007`; subjective motion feel still benefits from Aaron's daily use.
- Automatic app detection currently uses the active application's bundle/name,
  not the focused field or surrounding document content.
- The measured local rewrite added 1.03 seconds on this fixture. Longer prompt
  distributions still need measurement; the hard deadline prevents an
  unbounded wait.
- Cancellation during the insertion stage is intentionally disabled because
  paste may already have occurred.
