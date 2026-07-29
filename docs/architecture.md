# Architecture

## Product contract

This repository is Aaron's fork of `digimata/parrot`. It deliberately diverges
from upstream's ultra-minimal dictation-daemon charter. Merge compatibility is
not a design goal.

The product is a daily-use Apple-platform dictation app in the Wispr Flow
class, with one defining advantage: microphone audio and transcript text stay
on the device that captured them. macOS is the mature primary surface. The
first mobile target is Aaron's iPhone 17 Pro.

## Product identity

The public product, app, executable, package, and repository are named
**Wordhand**. The command-line executable is `wordhand`, and the stable product
data directory is `~/Library/Application Support/Wordhand`.

The pre-fork name, Parrot, survives only where required for upstream attribution
and automatic migration. It is not a secondary brand. Existing user data is
copied once into the Wordhand directory, while the legacy directory is
preserved as a rollback copy.

Done means a signed, installable app that:

1. records from configurable hold-to-talk or tap-toggle shortcuts;
2. transcribes locally with Core ML on Apple silicon;
3. inserts reliable, well-formatted text at the active cursor;
4. learns user terms through a custom dictionary;
5. keeps a searchable, reusable local transcript history;
6. supports paste, copy-only, and direct Unicode insertion modes;
7. exposes understandable settings, permissions, model state, and failures;
8. has automated tests plus receipts from real use in native, browser, and
   Electron targets.

This file describes the intended architecture for that product. Features marked
"planned" are not claims about the current binary.

## Product principles

- Local by default and by promise. Audio and transcript content must not leave
  the machine. Any future network behavior affecting either requires Aaron's
  explicit approval.
- Reliability beats cleverness. Losing a transcript or silently failing to
  insert it is worse than a visible delay.
- Every transcript is recoverable. The app stores the final local transcript
  before attempting insertion.
- Failures are legible. Permission, secure-input, model-download, hotkey, audio,
  transcription, and insertion failures need distinct user-facing states.
- Each phase ships a usable vertical slice. Do not leave four features half
  connected.
- Hardware APIs sit behind narrow protocols. Pure text, settings, dictionary,
  history, and routing logic remain deterministic and testable.
- macOS is the only supported platform. Native AppKit and SwiftUI are preferred
  over web shells or sidecar services.

## Explicit non-goals

- Platforms outside macOS and iOS.
- Cloud transcription or cloud post-processing.
- Uploading audio, transcripts, dictionary entries, history, or surrounding
  application text.
- Meeting recording, speaker diarization, or team collaboration in the core
  dictation product.
- Preserving a small diff from upstream.

## Current implementation

Verified by source inspection and dated receipts on 2026-07-28:

- Swift Package Manager library, executable, and test targets for macOS 14+;
- WhisperKit transcription with three registered local Whisper models;
- `AVAudioEngine` capture converted to 16 kHz mono Float32;
- configurable global shortcuts through `CGEventTap`, including hold-to-talk
  and tap-to-start/tap-to-stop modes;
- direct Unicode cursor insertion through `CGEvent`;
- native recording overlay, branded menu bar control, Dock presence, and
  Settings window;
- persistent custom dictionary with immediate correction flow;
- searchable SQLite transcript history with copy, reinsert, correction, and
  deletion actions;
- versioned settings and automatic migration from the legacy product name;
- permission doctor, setup, and LaunchAgent commands;
- macOS continuous integration for tests and release builds.

An iOS host app, custom keyboard extension, shared local handoff core, and two
on-device engine adapters are now present on the `codex/ios17-pro` development
branch. Their source has not been compiled with an iOS SDK or driven on an
iPhone because this Mac currently has Command Line Tools only. They are not
promoted to shipped behavior until the device receipt in
`docs/verification/2026-07-28-ios-foundation.md` is completed.

Paste-based insertion, the remaining preferences surfaces, signed app bundle,
notarization, and updates remain planned. Only measured receipts may promote
latency or compatibility claims.

## Current delivery state

P0 ground truth and P1 foundation are complete as of 2026-07-28. The package
now has `WordhandCore`, protocol-backed coordinator seams, versioned settings,
41 deterministic tests, and macOS CI.

P2 custom dictionary is implemented but not yet through its live three-target
exit gate. Its current runtime path is:

```text
~/Library/Application Support/Wordhand/dictionary.json
  -> versioned DictionaryStore
  -> MutableTranscriptProcessor
  -> coordinator processing stage
```

The menu-bar app exposes a native management window and a
`Correct Last Transcript…` action. Management changes update the running
processor without a restart. Phrase entries show their replacement preview
before being committed. See
`docs/verification/2026-07-28-dictionary.md` for observed behavior and the
remaining receipt.

P3 transcript history is implemented behind a local SQLite store. The
coordinator saves processed and raw transcript text before attempting
insertion, then records success or the recoverable failure reason. A native
split history window supports Unicode-aware search, copy, reinsert, correction
creation, delete, clear-all, metadata, and visible failure states.

The app now has a regular Dock presence as well as its menu bar item. Clicking
the Dock item with no visible windows opens Settings. Its minimal app icon pairs
a monoline `W` with a mint text cursor, giving the Dock and public repository
one identity. See `docs/verification/2026-07-28-history.md` for the original
isolated UI receipt and the remaining microphone exit gate.

Control-Space remains the default, but is no longer hard-coded. The native
Settings window records up to four modified-key bindings, persists them, and
applies them to the running event tap without a restart. Each recording binding
can use hold-to-talk or tap-to-start/tap-to-stop behavior. Duplicate and bare
shortcuts are rejected, and the known macOS Control-Space input-source conflict
is surfaced. The edge logic is isolated in `WordhandCore`, rejects unintended
modifier combinations, ignores repeat events, and recovers if a required
modifier is released first. See
`docs/verification/2026-07-28-settings-hotkeys.md` for the automated and live
receipt plus the remaining three-target exit gate.

## Target structure

The package separates testable product logic from platform adapters:

```text
Package.swift
Sources/
  WordhandCore/                 pure and persistence-facing product logic
    Models/
    Settings/
    TextProcessing/
    Dictionary/
    History/
    Insertion/
    Hotkeys/
  WordhandMac/                  AppKit, AVFoundation, CoreGraphics adapters
    Audio/
    Transcription/
    Input/
    Permissions/
    UI/
  wordhand/                     executable wiring and CLI compatibility
  WordhandMobileCore/           App Group handoff and local benchmark storage
Mobile/
  WordhandMobile/               iOS recorder and on-device transcription host
  WordhandKeyboard/             lightweight cursor insertion extension
  Shared/                       matching App Group configuration
Tests/
  WordhandCoreTests/
  WordhandMacTests/             adapter contract tests with fakes where possible
```

Migration may happen incrementally. The important boundary is behavioral: core
logic must not require a microphone, Accessibility permission, an active text
field, or a loaded Whisper model to run its tests.

## End-to-end data flow

```text
shortcut event
  -> recording coordinator
  -> audio capture
  -> local transcriber
  -> transcript processor
       sanitize model tokens
       apply dictionary
       format for active application
       apply local voice commands
  -> history store (before insertion)
  -> insertion router
       paste with clipboard preservation
       direct Unicode fallback
       copy-only
  -> result/undo state
  -> overlay, menu bar, history, and preferences UI
```

The coordinator owns one explicit state machine:

```text
idle -> recording -> transcribing -> processing -> inserting -> idle
                         \-> failed/recoverable -> idle
```

Repeated presses, a release without a matching press, overlapping transcription,
and shutdown during work must have defined behavior and tests.

## Core contracts

The hardware-touching paths should conform to protocols:

```swift
protocol AudioCapturing {
    func start() throws
    func stop() -> [Float]
}

protocol Transcribing {
    var modelID: String { get }
    func transcribe(_ audio: [Float]) async throws -> String
}

protocol TextInserting {
    func insert(_ text: String, mode: InsertionMode) async throws
}

protocol HotkeyMonitoring {
    func start(handler: @escaping (HotkeyEvent) -> Void) throws
    func stop()
}

protocol TranscriptStoring {
    func save(_ transcript: Transcript) throws
    func search(_ query: String) throws -> [Transcript]
}
```

Concrete adapters use AVFoundation, WhisperKit, CoreGraphics, AppKit,
`NSPasteboard`, and local file persistence. Tests use deterministic fakes.

## Transcript processing

Processing is an ordered pipeline of pure transformations. Each stage receives
text plus a small context value and returns text plus optional diagnostics.

Initial order:

1. sanitize model control and non-speech tokens;
2. normalize whitespace;
3. apply custom dictionary replacements;
4. apply conservative punctuation and capitalization;
5. apply application-specific formatting when enabled;
6. interpret explicitly supported voice commands;
7. produce the final transcript stored in history.

The raw model output may be retained inside the same local history record for
debugging and future reprocessing. Nothing in this pipeline may call a remote
model.

## Custom dictionary

Dictionary entries are local, ordered, and deterministic:

- spoken form;
- replacement text;
- match mode such as word, phrase, or case-insensitive;
- enabled state;
- created and updated timestamps.

Longer phrases win before shorter phrases. Word entries respect Unicode word
boundaries. Replacements must not recursively reprocess their own output.

The UI includes normal add/edit/delete management and a one-gesture action that
uses the most recent transcript to create a correction while the error is still
fresh.

## Transcript history

History is a local append-first store with stable identifiers, timestamps,
model/language metadata, raw output, processed output, insertion mode, target
application identifier when available, duration, latency, and result status.

The history window supports:

- newest-first browsing;
- text search;
- copy;
- re-insert into the current target;
- create dictionary correction;
- delete one record and clear all with confirmation;
- configurable retention.

The transcript is saved before insertion, so an Accessibility or secure-input
failure never loses the words.

## Insertion and clipboard behavior

Paste is the default insertion strategy because Electron and Java applications
often mishandle synthetic Unicode key events.

Paste insertion:

1. snapshot all current pasteboard items and change count;
2. place transcript text on the pasteboard;
3. send Command-V;
4. wait for the target to consume the paste;
5. restore the previous pasteboard only if no third party changed it in the
   meantime;
6. report a recoverable failure instead of silently discarding text.

Direct Unicode insertion remains a fallback. Copy-only intentionally leaves the
transcript on the clipboard. The last successful insertion keeps enough local
state for an immediate undo/revert command.

When secure input or an inaccessible target is detected, the app keeps the
transcript in history, copies it if safe, and tells the user what happened.

## Hotkeys

Bindings are data, not hard-coded `fn` checks. A binding contains modifiers,
key code or supported modifier-only key, trigger mode, and action.

The initial actions are push-to-talk, toggle recording, copy last transcript,
open history, and undo last insertion. Settings must allow more than one
binding, reject invalid combinations, detect conflicts the app can observe, and
warn when macOS owns the selected shortcut.

`fn` remains a supported default for continuity, never a requirement.

## User interface

The app runs as a Dock-present macOS application and retains its menu bar
control. Its native windows are:

- onboarding and permission repair;
- preferences;
- custom dictionary;
- transcript history;
- model download and language state.

The existing overlay remains the immediate recording/transcribing/error
surface. Menu and window copy must describe recovery actions rather than expose
internal errors.

## Settings and persistence

Settings use a versioned `Codable` schema stored under the app's Application
Support directory. Writes are atomic. Invalid or newer schemas preserve the
original file and fall back visibly rather than overwriting user data.

User data stays under:

```text
~/Library/Application Support/Wordhand/
  settings.json
  dictionary.json
  history.sqlite
  Models/
```

On the first branded launch, Wordhand copies an existing
`~/Library/Application Support/Parrot` directory into this location through a
staged migration. It never overwrites an existing Wordhand directory and
preserves the legacy directory for rollback.

The final macOS app bundle and bundle identifier will determine the stable TCC
identity. Development builds must not pretend their permission grants prove the
signed release identity works.

For isolated development and verification, `wordhand run --data-directory`
redirects settings, dictionary, and history persistence to an explicit local
directory.

## Testing strategy

`swift test` is the minimum local gate. CI runs it on a supported macOS runner
and builds the release configuration.

Pure tests cover:

- model registry invariants;
- sanitizer and formatting stages;
- dictionary matching, precedence, Unicode boundaries, and persistence;
- settings defaults, migrations, validation, and atomic-write recovery;
- history insertion, search, retention, and deletion;
- insertion routing and clipboard restoration decisions;
- hotkey parsing, serialization, validation, conflicts, and coordinator states.

Adapter tests use fakes for pasteboard, event posting, active application,
clock, filesystem, transcriber, capture, and hotkey monitor. Hardware behavior
still requires manual receipts.

Release verification includes real dictation into:

1. a native AppKit text field;
2. a browser text field;
3. an Electron application.

Each receipt records the command or gesture, target app, observed text, and
post-release latency measured from a monotonic clock.

## Distribution

The shipping form is a signed and notarized `.app`, distributed in an
installable disk image or package. A stable bundle identifier and signing
identity are required for reliable TCC permissions. The release path must not
strip quarantine attributes.

Release automation will build, test, sign, notarize, staple, publish checksums,
and produce an update feed. Publishing, certificate selection, and any paid
service remain Aaron-gated actions.

The inherited upstream repository currently has no software license. Public
source visibility is allowed, but an installable project release must not be
described as carrying an open-source license until provenance is resolved. See
`NOTICE.md`.

## iPhone architecture

iOS does not give a custom keyboard extension microphone access. Wordhand
therefore keeps the model and microphone in the containing app:

```text
Wordhand keyboard Record
  -> wordhand://record opens containing app when iOS permits
  -> private 16 kHz mono CAF recording
  -> AudioFileTranscribing engine in host app only
       Apple Speech with requiresOnDeviceRecognition = true
       or explicitly selected Whisper Large v3 626 MB model
  -> shared TranscriptProcessor and dictionary boundary
  -> protected atomic draft in App Group
  -> return to previous app
  -> keyboard textDocumentProxy.insertText
  -> consume only the inserted draft ID
```

The App Group contains only one processed pending draft. Raw audio, raw model
output, latency, engine identity, and thermal observations stay in the
containing app's private Application Support directory for cross-platform
accuracy benchmarking. The keyboard never loads a speech model. iOS requires
Full Access for App Group handoff, but the extension has no network client and
sends no content anywhere.

Apple Speech is the bootstrap engine, not the accuracy winner by assumption.
The named WhisperKit candidate is
`openai_whisper-large-v3-v20240930_626MB`. Choosing it in the host app is the
explicit one-time model-download action. The default may change only after both
engines run the same local corpus on Aaron's iPhone 17 Pro and the receipt
records word accuracy, post-stop latency, peak memory, and thermal behavior.
