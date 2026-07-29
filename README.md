<p align="center">
  <img src="docs/assets/wordhand-icon.svg" width="128" height="128" alt="Wordhand app icon">
</p>

<h1 align="center">Wordhand</h1>

<p align="center">
  <strong>Local dictation for Mac.</strong><br>
  Hold Control-Space, speak naturally, and put the result at your cursor.
</p>

<p align="center">
  <a href="https://github.com/ValyouHustlin/wordhand/actions/workflows/ci.yml"><img src="https://github.com/ValyouHustlin/wordhand/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-11161C?logo=apple" alt="macOS 14 or newer">
  <img src="https://img.shields.io/badge/Apple%20Silicon-required-11161C" alt="Apple Silicon required">
  <img src="https://img.shields.io/badge/processing-on%20device-167D68" alt="Processing happens on device">
</p>

Wordhand is a native macOS voice-to-text app built for the place dictation
actually belongs: the text field you are already using. It records only while
you hold the shortcut, transcribes on-device through WhisperKit and Core ML,
and inserts the result into ordinary Mac apps.

## What is working today

| | |
| --- | --- |
| **Private by architecture** | Audio and transcript processing stay on the Mac. There is no account, remote transcription API, analytics, or transcript sync. |
| **Push to talk** | Hold `Control-Space`, speak, and release. A compact overlay shows recording and transcription state. |
| **Custom dictionary** | Teach Wordhand names, acronyms, product terms, and exact replacements. Corrections apply without restarting. |
| **Recoverable history** | Search recent transcripts, inspect insertion status, copy, reinsert, correct, or delete them from a native window. |
| **A real Mac app** | Wordhand lives in both the menu bar and Dock. Clicking its Dock icon opens Settings; history and dictionary are one click away. |
| **Accuracy-first local model** | Optimized Whisper Large v3 is the default on capable Macs. Balanced and smaller Whisper models remain selectable. |
| **Reliable insertion** | Paste-first insertion works across native, browser, and Electron targets while restoring the previous rich clipboard. Direct typing and copy-only modes are available. |

<p align="center">
  <img src="docs/assets/wordhand-history.png" width="920" alt="Wordhand transcript history window">
</p>

## Source preview

Wordhand is usable from source today. A signed and notarized installer is still
in development, so the honest public path currently requires the Xcode command
line tools.

**Requirements:** macOS 14 or newer, an Apple silicon Mac, and approximately
1 GB of free space for the first model.

```sh
git clone https://github.com/ValyouHustlin/wordhand.git
cd wordhand
/usr/bin/xcrun swift build -c release
.build/release/wordhand setup
.build/release/wordhand run
```

On first launch, macOS asks for Microphone and Accessibility access. Those
permissions are required to capture speech and place text at the cursor.
For source builds, macOS associates these grants with the terminal application
that launches Wordhand; the future signed app will have its own stable identity.
macOS secure-input fields intentionally block text injection; Wordhand keeps
the transcript in history instead of treating a password field as a valid
target.

## Daily use

1. Put the cursor where the text should go.
2. Hold `Control-Space`.
3. Speak.
4. Release the shortcut.

The recording stays local, the transcript is saved to local history, and the
text appears at the cursor.

If macOS uses `Control-Space` to switch input sources, disable **Select the
previous input source** under **System Settings > Keyboard > Keyboard
Shortcuts > Input Sources**.

## Commands

```sh
wordhand                                 # run in the foreground
wordhand setup                           # permissions and model setup
wordhand doctor                          # diagnose permissions and shortcut conflicts
wordhand models list                     # list local transcription models
wordhand models download <id>            # download a model before first use
wordhand models benchmark <audio> --model <id>
wordhand install --launch-at-login       # register the current binary at login
wordhand install --uninstall             # remove the login agent
wordhand --model whisper-large-v3-turbo  # use a larger multilingual model
wordhand --no-overlay                    # hide the recording overlay
```

Existing data from the earlier Parrot-branded build is copied automatically
into `~/Library/Application Support/Wordhand` the first time Wordhand runs. The
old directory is preserved as a rollback copy.

## Built locally, tested honestly

The package contains a deterministic test target for the model registry,
settings, transcript processing, dictionary matching and persistence, history,
hotkey state, coordinator behavior, and data migration.

```sh
/usr/bin/xcrun swift test
/usr/bin/xcrun swift build -c release
```

Hardware-facing behavior still requires real Mac verification. Dated receipts
live in [`docs/verification`](docs/verification), including what was observed
and what remains unverified.

## Roadmap

The next daily-use slices are immediate undo/revert, conservative local
formatting, onboarding and permission repair, app-aware formatting, and a
signed release path. See
[the product roadmap](.plan/plan.md) and
[architecture](docs/architecture.md).

## Provenance and license status

Wordhand began as a fork of
[`digimata/parrot`](https://github.com/digimata/parrot) and has deliberately
grown beyond that project's minimalist scope.

The upstream repository currently contains no software license. This repository
is therefore public source, but it is not yet accurate to describe the inherited
code as carrying an open-source license. See [NOTICE.md](NOTICE.md) for the
exact status. Resolving that provenance is a release prerequisite.
