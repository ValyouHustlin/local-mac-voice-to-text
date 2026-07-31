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
| **Decode-aware dictionary** | Teach Wordhand names, acronyms, product terms, and exact replacements. Canonical spellings condition Whisper before decoding; post-processing remains as a fallback. Changes apply without restarting. |
| **Recoverable history** | Search recent transcripts, inspect insertion status, copy, reinsert, or delete them. When Wordhand misses, save the corrected text against that exact local transcript and, when Quality Lab is enabled, its retained recording. |
| **A real Mac app** | Wordhand lives in both the menu bar and Dock. Clicking its Dock icon opens Settings; history and dictionary are one click away. |
| **Ready after login** | The installed app can register as a native macOS login item. Its interface and shortcut become available immediately while the selected speech model warms in the background. |
| **Accuracy-first local model** | Optimized Whisper Large v3 is the default on capable Macs. Balanced and smaller Whisper models remain selectable. |
| **Natural self-corrections** | Say “wait, no,” “I meant,” “make that,” or “scratch that.” Wordhand removes the abandoned wording locally before formatting. |
| **Maximum Performance preview** | On high-end Apple silicon, opt into formatter prewarming while you speak. Final transcription uses the complete audio buffer in every mode so speed never comes from risking dropped words. |
| **Reliable insertion** | Paste-first insertion works across native, browser, and Electron targets while restoring the previous rich clipboard. Direct typing and copy-only modes are available. |
| **Private Quality Lab** | Optionally retain local WAVs paired to corrected transcript references for accuracy evaluation. It is off by default, owner-only, automatically expires, stays under a selectable storage ceiling, and never uploads. |
| **Safe retry and undo** | When a text field exposes its cursor, Wordhand acknowledges delivery, retries one proven no-op, and can remove only its own last verified insertion. |
| **Flow-focused feedback** | Quiet start/stop tones, an expressive live waveform, a display-following recording control, and one-click cancellation keep dictation legible without demanding attention. |
| **Four writing styles** | Choose Casual, Formatted, Professional, or AI Communication. AI mode keeps connected reasoning as prose and uses lists, steps, or lightweight sections only when the content calls for them. The three richer modes use Apple’s on-device model with meaning-preservation checks and safe local fallback. |
| **Restart without hunting** | Settings that require a restart expose an inline Relaunch button only after their value changes. Current live-updating settings stay out of the way. |

<p align="center">
  <img src="docs/assets/wordhand-history.png" width="920" alt="Wordhand transcript history window">
</p>

## Install from source

Wordhand builds into a normal development app bundle with a Dock icon and menu
bar control. A Developer ID signature and notarized public download are still
in development, so the honest public path currently requires the Xcode command
line tools. Source installs deliberately use the separate
`com.valyou.wordhand.dev` identity and cannot register a login item.

**Requirements:** macOS 14 or newer, an Apple silicon Mac, and approximately
1 GB of free space for the first model.

```sh
git clone https://github.com/ValyouHustlin/wordhand.git
cd wordhand
./scripts/install-app.sh
```

This installs `Wordhand Dev.app` in `/Applications` when that directory is
writable (otherwise `~/Applications`), moves rollback copies outside the
searchable Applications folders with a non-launchable backup suffix, keeps
build output out of Spotlight, registers the installed app, and opens it. It
does not create a LaunchAgent, login item, or background item. Local source
builds are ad-hoc signed by default; they are not a substitute for the planned
notarized public release. The installer refuses to replace an existing app when
its signing requirement changes, because doing so could reset macOS privacy
permissions.

For repeated local development installs, use one persistent Keychain
code-signing identity so macOS sees each rebuild as the same app:

```sh
./scripts/configure-local-signing.sh "Your Code Signing Identity"
./scripts/install-app.sh
```

The configuration stores only the identity's display name at
`~/Library/Application Support/Wordhand/signing-identity`; the private key
remains in Keychain. Updates are staged and must preserve the installed plist
identifier, signed identifier, Team ID, and designated signing requirement
before Wordhand is stopped or replaced. The public release path still requires
resolved source provenance, selected Developer ID and notarization credentials,
an authenticated update manifest, and attended install/update evidence.

The inherited tag publisher and remote shell installer are retired. Wordhand
does not currently publish binary downloads. Its nonpublishing release builder
can produce and locally verify a hardened, notarized disk image only when an
explicit signing identity, Team ID, notary profile, version, build number, and
exact clean source commit are supplied; it never uploads or installs the
result.

Launch at login is intentionally release-only. The signed release will keep the
canonical `com.valyou.wordhand` identity across updates and expose the toggle in
Settings. Development installers reject `--launch-at-login` so rebuilding
cannot repeatedly trigger macOS Background Items approval.

On first launch, Wordhand opens a Welcome window with separate, explicit actions
for Microphone, Input Monitoring, and Accessibility access; merely presenting
the window does not trigger a system prompt. Input Monitoring detects the global
shortcut, Accessibility inserts the result, and Microphone captures speech. macOS
secure-input fields intentionally block text injection; Wordhand keeps the
transcript in history instead of treating a password field as a valid target.

## Daily use

1. Put the cursor where the text should go.
2. Hold `Control-Space`.
3. Speak.
4. Release the shortcut.

The recording stays local, the transcript is saved to local history, and the
text appears at the cursor.

### Privacy boundaries

Wordhand does not send audio, transcripts, dictionary terms, or formatting
prompts to a server. Whisper decoding runs in the local WhisperKit/Core ML
pipeline. AI-prompt formatting uses Apple's on-device Foundation Models
framework when available and deterministic local cleanup otherwise.

User vocabulary, settings, and transcript history live only under
`~/Library/Application Support/Wordhand`. The public repository ships a
versioned starter vocabulary, then installs it as ordinary editable dictionary
entries. Future starter updates merge non-destructively; a term a user deletes
does not silently return at the same seed version. Dictionary files are
owner-readable only (`0600`), as are settings and history; their containing
directory is owner-accessible only (`0700`). Wordhand prioritizes recent user
corrections and uses at most 24 canonical terms per decode so a large dictionary
does not drown out the terms that matter now. Editable pronunciation variants
also tell the recognizer that, for example, a commonly heard phrase is written
with a particular canonical spelling; the same entry remains a deterministic
post-processing fallback.

Quality Lab audio retention is disabled by default. When explicitly enabled,
16 kHz mono WAV files are kept under
`~/Library/Application Support/Wordhand/Quality Recordings`, named by their
matching transcript-history IDs, restricted to the current user, and deleted
automatically after the selected retention window. A selectable 250 MB–10 GB
aggregate ceiling removes the oldest recordings first. From the menu bar or
History, **Improve Last Transcript Accuracy…** saves what Wordhand should have
heard in the matching local history row. These pairs make controlled evaluation
and future local fine-tuning possible; Wordhand does not train on them
automatically and does not upload them.

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
wordhand dictionary add --heard-as "tee mux" --replace-with "tmux"
wordhand format "dictated text" --style professional
wordhand quality status
wordhand quality enable --retention-days 7
wordhand quality disable
wordhand quality clear --confirm
wordhand install --launch-at-login       # signed release app only
wordhand install --uninstall             # remove release/legacy registration
wordhand --model whisper-large-v3-turbo  # use a larger multilingual model
wordhand --no-overlay                    # hide the recording overlay
```

Existing data from the earlier Parrot-branded build is copied automatically
into `~/Library/Application Support/Wordhand` the first time Wordhand runs. The
old directory is preserved as a rollback copy.

## Built locally, tested honestly

The package contains a deterministic test target for the model registry,
settings, transcript processing, dictionary matching, decode-prompt generation
and persistence, history, hotkey state, coordinator behavior, and data
migration.

```sh
/usr/bin/xcrun swift test
/usr/bin/xcrun swift build -c release
```

Hardware-facing behavior still requires real Mac verification. Dated receipts
live in [`docs/verification`](docs/verification), including what was observed
and what remains unverified.

### Development safety

Wordhand's interactive runtime owns a global keyboard event tap and can post
synthetic input into the focused application. Do not run it unattended on a Mac
with other active work. Set `WORDHAND_SAFE=1` to make the `run` command refuse
startup before it installs global input:

```sh
WORDHAND_SAFE=1 .build/debug/wordhand run
```

Contributors should exercise shortcut and insertion behavior through the fake
adapters in `WordhandMacTests`. A real development tap test requires explicit
opt-in, a maximum 30-second timeout, active attendance, and a clear terminal
dedicated to the test. The immediate kill command is
`/usr/bin/pkill -x wordhand`.

## Roadmap

The remaining release work is a fresh-account pass, source-provenance
resolution, authenticated update metadata, credential selection, and attended
notarized install/update evidence.
See
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
