# Parrot

A fully local macOS dictation app: hold a shortcut, speak, and get private
on-device transcription at the cursor.

## Try the source build

```sh
git clone https://github.com/ValyouHustlin/local-mac-voice-to-text.git
cd local-mac-voice-to-text
swift build -c release
.build/release/parrot setup
.build/release/parrot run
```

**Requires:** macOS 14+, Apple silicon (M1 or newer), and the Xcode command-line
tools. Transcription runs locally through WhisperKit and Core ML. A signed,
notarized public installer is still on the roadmap; the source build is the
honest preview path today.

## How to use

1. **Run it.** Start `.build/release/parrot run`, or register that build with
   `.build/release/parrot install --launch-at-login`.
2. **Click into the text field you want to dictate into** — Messages, the address bar, a Slack thread, anywhere a cursor blinks.
3. **Hold `Control-Space`, speak, release.** A small pill appears at the bottom of the screen while the mic is hot.
4. **The transcript types itself in at the cursor** after local transcription
   finishes.

That's it. There is no record button, no stop button, no "send" — hold
`Control-Space` while you speak, then release it.

> **Shortcut conflict:** macOS can reserve `Control-Space` for switching input
> sources. Disable “Select the previous input source” under System Settings →
> Keyboard → Keyboard Shortcuts → Input Sources if Parrot reports a conflict.

## CLI

```sh
parrot                                 # run in the foreground (^C to quit)
parrot setup                           # one-time setup: permissions + model download
parrot install --launch-at-login       # register a LaunchAgent (background daemon)
parrot install --uninstall             # remove the LaunchAgent
parrot doctor                          # check permissions + Control-Space
parrot models list                     # list available models
parrot models download <id>            # pre-download a model
parrot --model whisper-large-v3-turbo  # bigger, multilingual, slower first-run
parrot --no-overlay                    # disable the bottom-of-screen pill
```

## Stack

- **Swift** — single SPM executable target
- **WhisperKit** — Whisper inference via CoreML, ANE-accelerated
- **AVAudioEngine** — mic capture
- **CGEventTap** — global hotkey
- **CGEvent** — text injection at cursor
- **NSWindow** (borderless, click-through) — recording-indicator pill

See [docs/architecture.md](docs/architecture.md) for design notes.

## Build from source

```sh
swift build -c release
.build/release/parrot --help
```
