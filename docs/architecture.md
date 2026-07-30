# Architecture

## Product contract

This repository is Aaron's fork of `digimata/parrot`. It deliberately diverges
from upstream's ultra-minimal dictation-daemon charter. Merge compatibility is
not a design goal.

The product is a daily-use macOS dictation app in the Wispr Flow class, with one
defining advantage: microphone audio and transcript text stay on the Mac.

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
- Custom vocabulary and formatting instructions are local runtime inputs. They
  may be persisted only in Wordhand's application-support directory and may
  never be sent to remote model, analytics, sync, or logging services.
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

## Development and shared-machine safety

Wordhand's real runtime installs a session-wide `CGEventTap` and can post
synthetic keyboard events into whichever application is focused. On Aaron's
shared development Mac, agent lanes must never leave `wordhand run` or another
interactive global-input path unattended. `--skip-doctor` is not isolation and
does not make an unattended run safe.

Development verification uses `HotkeyMonitoring` and `TextInserting` protocols
with injected fake tap controllers and fake event posters. Offline model
benchmarks, builds, and tests are allowed because they do not install global
input or post keystrokes.

The startup kill switch is:

```sh
WORDHAND_SAFE=1 wordhand run
```

Safe mode must refuse the run before model warm-up, event-tap installation,
audio capture, or text-injector setup.

A deliberate real tap test must stay attended and use both
`--allow-global-input-test` and `--global-input-test-timeout-seconds` with a
value from 1 through 30. The timer self-terminates the process. The immediate
manual kill path is `/usr/bin/pkill -x wordhand`, followed by
`/usr/bin/pgrep -x wordhand` to confirm no process remains.

This is a development constraint, not a relaxation of the end-user product
goal. Normal user-owned use remains frictionless. Agent lanes prefer isolated
adapters and fakes, and keep any necessary live run short, deliberate,
time-bounded, and attended.

## Explicit non-goals

- Cross-platform support.
- Cloud transcription or cloud post-processing.
- Uploading audio, transcripts, dictionary entries, history, or surrounding
  application text.
- Meeting recording, speaker diarization, or team collaboration in the core
  dictation product.
- Preserving a small diff from upstream.

## Current implementation

Verified by source inspection and dated receipts through 2026-07-29:

- Swift Package Manager library, executable, and test targets for macOS 14+;
- Argmax OSS/WhisperKit 1.0 transcription with four registered local Whisper
  models; optimized Large v3 (626 MB) is the accuracy-first default;
- `AVAudioEngine` capture converted to 16 kHz mono Float32, using 1024-frame
  input buffers and an 80 ms post-release tail to retain final phonemes;
- configurable global shortcuts through `CGEventTap`, including hold-to-talk
  and tap-to-start/tap-to-stop modes;
- paste-first cursor insertion with rich clipboard restoration, copy-only mode,
  direct Unicode fallback, Secure Input detection, cursor acknowledgement,
  one safe retry after a proven no-op in editor surfaces with reliable cursor
  reporting, and guarded undo of the last verified insertion;
- native recording overlay, branded menu bar control, Dock presence, and
  Settings window;
- quiet local start/stop/cancel cues, an expressive eleven-bar waveform, a
  pointer-display-following capsule overlay, a text-free rotating 3×3 processing
  indicator, and one-click cancellation that discards work before insertion;
- four explicit writing profiles: Casual, Formatted, Professional, and AI
  Communication; richer profiles use Apple's on-device system language model
  and fall back to deterministic cleanup when unavailable;
- deterministic spoken-repair handling for explicit phrases such as
  `wait, no`, `I meant`, `make that`, and `scratch that`, while preserving
  ordinary semantic uses of `no` and `I meant`;
- Adaptive and Maximum processing modes; Maximum keeps the local formatter
  prepared while both daily-runtime modes use authoritative full-buffer
  transcription;
- duplicate-process prevention, a 10-minute recording safety stop, active
  Whisper cancellation, and rewrite validation that rejects dropped numbers,
  technical tokens, or negated constraints;
- persistent custom dictionary with versioned, non-destructive editable
  defaults and immediate correction flow;
- searchable SQLite transcript history with copy, reinsert, dictionary
  correction, corrected-reference labeling, and deletion actions;
- opt-in local Quality Lab audio retention with automatic expiry, a selectable
  aggregate storage ceiling, and owner-only storage; public installs keep it
  disabled by default;
- versioned settings and automatic migration from the legacy product name;
- permission doctor and visible in-app recovery that independently checks
  Microphone, Input Monitoring, and Accessibility instead of reporting a
  false-ready state;
- a stable native application bundle with configurable persistent local code
  signing, native login-item registration, standard Applications-folder and
  Spotlight registration, rollback copies stored outside searchable application
  folders, and a legacy LaunchAgent fallback for command-line-only builds;
- immediate menu, Dock, and shortcut readiness while the selected model warms
  asynchronously from a complete local cache without network validation;
- macOS continuous integration for tests and release builds.

Developer ID signing, hardened runtime, notarization, public packaging, a
fresh-account onboarding pass, and updates remain planned. Only measured
receipts may promote latency or compatibility claims.

## Current delivery state

P0 ground truth and P1 foundation are complete as of 2026-07-28. The package
now has `WordhandCore`, protocol-backed coordinator seams, versioned settings,
deterministic tests across core and macOS adapter targets, and macOS CI. The
current exact count belongs in the latest verification receipt rather than this
long-lived architecture document.

The daily-driver bundle is built by `scripts/build-app.sh` and installed by
`scripts/install-app.sh`. The installer prefers `/Applications`, falls back to
`~/Applications` when needed, explicitly registers/imports the bundle, and keeps
rollback bundles under Application Support with a non-launchable
`.app-backup` suffix so Spotlight and LaunchServices see one active Wordhand.
The build-output directory carries a `.metadata_never_index` marker and is
explicitly unregistered after installation. Installed builds use
`SMAppService.mainApp` for native
launch at login. Ad-hoc signing is the public source-build fallback, but it
changes the app's code identity on each rebuild and can invalidate macOS privacy
grants. A local identity selected once through
`scripts/configure-local-signing.sh` is reused automatically by future builds;
the file stores only its display name while the private key stays in Keychain.
The UI starts before model warmup; a complete local WhisperKit
cache is opened with downloading disabled, while a missing cache falls back to
the explicit download path. Settings, dictionary, history, and the data
directory are hardened to owner-only permissions.

P2 custom dictionary now drives both transcription stages. Its runtime path is:

```text
~/Library/Application Support/Wordhand/dictionary.json
  -> versioned DictionaryStore
  -> DictionaryVocabularySource
       -> Whisper tokenizer
       -> WhisperKit DecodingOptions.promptTokens
  -> MutableTranscriptProcessor post-decode fallback
  -> coordinator processing stage
```

The menu-bar app exposes a native management window and a
`Correct Last Transcript…` action. Management changes update the running
decoder prompt and fallback processor without a restart. The repository's
starter terms live in an editable JSON resource with an integer seed version.
On upgrade, missing new defaults merge into the user's local dictionary without
overwriting custom entries or restoring terms deleted at the current seed
version. Files are forced to owner-only `0600` permissions. Decode prompts
prioritize user-created corrections and cap starter fill at 24 terms, the
measured point that preserved five-term accuracy without the dilution observed
with the entire starter set.

The selected terms are written into Whisper's simulated prior-transcript
context in reverse priority order, placing the newest/highest-priority terms
nearest the decode boundary. The four strongest terms are repeated once at the
boundary. This matters because Whisper consumes `promptTokens` as preceding
transcript context rather than as an instruction; a live `Valyou -> value`
miss and identical controlled fixture confirmed that proximity plus one bounded
reinforcement was stronger than a leading vocabulary list. Wordhand does not
install a broad `value -> Valyou` post-hoc replacement.

When an editable entry's spoken form differs from its canonical replacement,
Wordhand also writes up to eight recent pronunciation associations into that
same local prior-transcript context. One entry therefore drives both recognition
paths: decode-time conditioning first and deterministic `spoken form ->
replacement` matching afterward if decoding still emits the alias. Multiple
pronunciations use multiple editable rows with the same canonical replacement;
the persistence schema does not need a special-case name model. The associations
are constructed only from the local dictionary and never leave the process.
An identical silent audio fixture moved `Aaron Browne-Moore` and `tmux` from
two of four exact occurrences to four of four. See
`docs/verification/2026-07-29-pronunciation-aliases.md`.

WhisperKit exposes `DecodingOptions.promptTokens`, but its 1.0 decoder can honor
an end-of-text sample while it is still forcing those prompt tokens. Large v3
then returns an empty transcript. Wordhand supplies a narrow `TextDecoding`
adapter that defers sampled completion and the first-token confidence check
only until forced prompt prefill ends. The underlying Core ML decoder, token
sampler, thresholds after prefill, and cancellation path remain unchanged.
See `docs/verification/2026-07-28-decode-vocabulary.md`.

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

Optimized Whisper Large v3 is the default for new installs and is active on
Aaron's Mac. A repeatable `wordhand models benchmark` command measures model
load, transcription latency, real-time factor, and exact output against the
same local audio. Settings exposes model choice, with an explicit relaunch note.
The smaller 1024-frame microphone tap and 80 ms capture tail prioritize complete
last words. On the local 11.00-second JFK fixture, Base transcribed in 0.742
seconds and Large v3 in 1.025 seconds; both were correct, with Large producing
slightly stronger punctuation. Audio longer than one Whisper model window uses
WhisperKit's local voice-activity chunker to split at silence and decode chunks
concurrently. This applies to Adaptive long dictation and the authoritative
full-buffer final decode in Maximum mode; sub-window recordings keep the same
single-decode path. Maximum's rolling windows are never joined into the final
text because their window-local segment boundaries can omit speech or leak
decoder control tokens. The offline benchmark supports `--streaming` to replay
that exact rolling/finalization path without microphone capture, playback,
global input, or text injection. See
`docs/verification/2026-07-29-long-dictation-vad.md` and
`docs/verification/2026-07-29-streaming-tail-overlay.md`.

Paste is now the live default instead of merely a stored setting. Wordhand
snapshots every pasteboard item/type, stages the transcript, posts Command-V,
and restores the original clipboard only if no newer clipboard write won the
race. The first paste from each process receives a 120 ms pasteboard settle
interval; later pastes use 40 ms before Wordhand
posts a complete Command-down, V-down, V-up, Command-up chord from a combined
session event source. Cursor observation waits 360 ms for slower targets.
When Accessibility exposes a reliable editor element and selection, an
unchanged cursor proves a no-op and permits exactly one retry. Terminal
accessibility surfaces are not reliable editor cursors: Ghostty was observed
leaving its reported selection unchanged after consuming a paste. Wordhand
therefore sends exactly one paste to known terminal applications and treats an
unchanged selection there like an unsupported compatibility surface. A moved
or changed target is still a recoverable failure. Fields that do not expose
selection retain the same compatibility fallback and cannot be honestly marked
as verified.
The previous clipboard is restored on both success and failure.
Copy-only and direct Unicode remain selectable in Settings and update the
running coordinator without relaunching. Secure Input is checked before
mutation. Chrome and VS Code accepted complete live transcripts while an RTF
plus plain-text clipboard item was restored before this cold-start hardening.
See
`docs/verification/2026-07-28-accuracy-paste.md`.

The repaired installed-app checkpoint on 2026-07-29 reconfirmed paste insertion
into TextEdit, a focused Chrome textarea, and a VS Code untitled editor. It also
exposed that posting Command-V is not proof that the intended field received
the transcript: a browser advertising iframe took focus during one recording,
the textarea stayed empty, and history still recorded the paste as inserted.
See `docs/verification/2026-07-29-three-target-checkpoint.md`.

The last verified insertion retains only a focused-element checkpoint and text
range in memory. `Undo Last Insertion` is enabled in the menu bar only while
that proof remains available. Undo refuses to run if focus or the cursor moved;
it selects and deletes only Wordhand's verified range and never sends a broad
Command-Z that could revert unrelated user work. This acknowledgement, retry,
and undo path is fake-driven and must still receive an attended installed-app
receipt before being promoted to a three-target runtime claim. See
`docs/verification/2026-07-29-quality-lab-insertion.md`.

The recording surface is intentionally visually quiet: one shadowed matte
capsule, an eleven-bar mint waveform, and a bare compact cancel glyph. The
panel's second native shadow, status halo, divider, and outlined cancel control
are removed. Transcription, local formatting, and insertion use one text-free
3×3 rounded-square grid whose active perimeter square advances clockwise. The
overlay follows the pointer between displays, so the state stays visible on the
screen being used. Cancellation invalidates the current coordinator operation
before insertion and resets tap-toggle routing so the next shortcut starts
immediately. `wordhand overlay-preview` provides a safe visual-only inspection
path that installs no event tap and uses no audio.

Writing style is an explicit user choice rather than inferred from the active
application. Casual performs fast deterministic cleanup. Formatted preserves
natural tone while fixing structure. Professional improves organization and
wording conservatively. AI Communication makes goals and multiple requirements
scannable while selecting structure from meaning rather than sentence count:
connected reasoning and ordinary requests remain prose, parallel requirements
may become bullets, true sequences may become numbered steps, and lightweight
sections are reserved for complex execution briefs. A deterministic
sentence-count fallback must not override that semantic choice. The latter three
send only the current local transcript to Apple's on-device Foundation Models
framework. They do not read surrounding document content.

Generation has a proportional response budget and an eight-second deadline.
An invalid first rewrite receives one stricter conservative retry; runtime
failure or a second rejection falls back to deterministic local cleanup.
Validation preserves digit-bearing values, technical tokens, acronyms,
negations, speaker perspective, modality, uncertainty, and requested-action
markers in addition to bounding rewrite length. Legacy Automatic, Polished,
AI-prompt, and Verbatim settings migrate to the closest new style. See
`docs/verification/2026-07-29-writing-modes.md` and
`docs/verification/2026-07-29-adaptive-ai-relaunch.md`.

Settings tracks the model loaded by the running process separately from the
persisted model choice. Changing the model reveals an inline Relaunch Wordhand
button in that card; changing back to the active model removes it. Live-updating
settings do not show restart UI. Relaunch uses a short detached local helper so
the old process can release its single-instance lock before LaunchServices opens
the same signed bundle. This preserves the stable application path and signing
identity used by macOS privacy permissions.

Explicit self-corrections are resolved deterministically before the selected
writing style runs. Maximum processing mode prewarms the matching local
Foundation Models session at startup and recording start, while bounding the
prepared-session cache. The rolling Whisper engine remains available to the
offline benchmark, where it decodes ordered audio every two seconds over a
maximum 20-second working window and keeps two trailing segments revisable. It
is disabled in the daily runtime because its composite cannot be trusted and
discarding that composite before a full decode only adds release latency. Both
runtime modes therefore decode the complete captured buffer once with
silence-aware chunking. This removes the boundary math that lost the end of a
48.69-second natural dictation and leaked decoder control tokens in an offline
replay without making users wait for unused rolling work. Quality takes
priority over the unsafe merge, and speed comes from avoiding redundant work.
Adaptive remains the public default and retains the lower-work single batch
path. See `docs/verification/2026-07-29-streaming-tail-overlay.md`.

The Whisper vocabulary prompt is tokenized once and reused until an editable
dictionary change produces a different prompt. The offline rolling experiment
also cancels an in-flight partial decode when finalization begins, because a
partial result has no value after the user has stopped and the complete buffer
is authoritative. On the same local 11.00-second fixture and Large v3 Turbo
model, one measured before/after run preserved identical text while
stop-to-final time moved from 2.167 seconds to 1.556 seconds. This measurement
describes the isolated rolling benchmark; daily runtime remains on the
authoritative full-buffer path.

The runtime now holds a per-data-directory process lock so a duplicate launch
cannot create two competing microphone, hotkey, or insertion owners. Toggle
recordings automatically stop and process at ten minutes instead of growing an
unbounded audio buffer. Cancel during Whisper decoding now signals WhisperKit's
progress callback and still invalidates the coordinator operation before any
insertion. See `docs/verification/2026-07-28-hardening.md`.

## Target structure

The package should separate testable product logic from macOS adapters:

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
       daily runtime retains one complete captured buffer
       offline rolling benchmark forwards chunks through one ordered stream
  -> local transcriber
       snapshot enabled canonical dictionary spellings
       prioritize recent user corrections; cap prompt at 24 terms
       tokenize them into WhisperKit promptTokens
       guard forced prompt prefill from premature completion
       decode locally with Core ML
       offline rolling benchmark stabilizes repeated rolling results
       daily runtime decodes the complete captured buffer once at release
  -> transcript processor
       sanitize model tokens
       apply dictionary corrections as a fallback
       remove unambiguous hesitation fillers
       resolve explicit spoken self-corrections
       resolve writing profile for active application
       optionally rewrite with Apple's on-device system language model
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

Repeated presses, a release without a matching press, explicit cancellation,
overlapping transcription, and shutdown during work must have defined behavior
and tests.

## Core contracts

The hardware-touching paths should conform to protocols:

```swift
protocol AudioCapturing {
    func start() throws
    func stop() async -> [Float]
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
4. remove unambiguous hesitation sounds such as `um`, `uh`, `erm`, and `hmm`
   deterministically, including stretched forms and surrounding pause
   punctuation; user dictionary substitutions take precedence;
5. resolve explicit spoken repairs such as `wait, no`, `I meant`, `make that`,
   `correction`, `scratch that`, and immediate false starts; ambiguous language
   is preserved rather than guessed;
6. apply the explicit Casual, Formatted, Professional, or AI Communication
   writing style;
7. validate on-device rewrites for facts, constraints, perspective, modality,
   and uncertainty, retry conservatively once, then use safe local fallback;
8. interpret explicitly supported voice commands;
9. produce the final transcript stored in history.

The raw model output may be retained inside the same local history record for
debugging and future reprocessing. Nothing in this pipeline may call a remote
model.

## Custom dictionary

Dictionary entries are local, ordered, and deterministic:

- spoken form or editable pronunciation variant;
- replacement text;
- match mode such as word, phrase, or case-insensitive;
- enabled state;
- created and updated timestamps.

Longer phrases win before shorter phrases. Word entries respect Unicode word
boundaries. Replacements must not recursively reprocess their own output.

The UI includes normal add/edit/delete management and a one-gesture action that
uses the most recent transcript to create a correction while the error is still
fresh. The same rows supply local decode-time pronunciation conditioning and
post-decode replacement fallback.

## Transcript history

History is a local append-first store with stable identifiers, timestamps,
model/language metadata, raw output, processed output, insertion mode, target
application identifier when available, duration, latency, and result status.

The history window supports:

- newest-first browsing;
- text search;
- copy;
- re-insert into the current target;
- create a dictionary correction;
- edit and save what Wordhand should have heard as a corrected local reference;
- delete one record and clear all with confirmation;
- configurable retention.

The transcript is saved before insertion, so an Accessibility or secure-input
failure never loses the words.

## Private Quality Lab

Audio retention is useful as an evaluation corpus, not as automatic training.
Wordhand therefore exposes an explicit Quality Lab toggle, retention window,
and aggregate recording-storage ceiling:

- public and fresh installs default to disabled;
- an existing user may opt in locally without changing the repository default;
- each 16 kHz mono WAV is named by the matching transcript-history UUID;
- no transcript text is duplicated into an audio manifest;
- the directory is owner-only `0700` and each WAV is owner-only `0600`;
- recordings expire after 1–90 days, with 7 days as the recommended default;
- the selectable storage ceiling defaults to 2 GB and removes the oldest WAVs
  first after startup, a limit change, or a retained capture;
- deleting one history record deletes its paired audio, and clearing history or
  using Delete All removes retained recordings;
- the menu-bar `Improve Last Transcript Accuracy…` action and History detail
  action save corrected reference text in the matching local history row;
- no upload, sync, analytics, or background training path exists.

The files inherit the Mac's volume-at-rest protection when FileVault is enabled;
Wordhand does not claim independent application-level encryption. Corrected
reference text now makes retained audio useful for controlled local evaluation.
A later fine-tuning workflow must keep all processing local and receive a
separate design and verification pass; Wordhand does not automatically train on
the corpus. See
`docs/verification/2026-07-29-quality-corrections-storage.md`.

## Insertion and clipboard behavior

Paste is the default insertion strategy because Electron and Java applications
often mishandle synthetic Unicode key events.

Paste insertion:

1. snapshot all current pasteboard items and change count;
2. place transcript text on the pasteboard;
3. wait 120 ms for the first process paste or 40 ms for later transactions;
4. send a complete Command-V key chord;
5. wait for the target to consume the paste and, where supported, confirm the
   expected cursor advance;
6. retry exactly once only when the same focused field has a reliable editor
   cursor and proves it did not move; never retry from terminal cursor evidence;
7. restore the previous pasteboard only if no third party changed it in the
   meantime;
8. report a recoverable failure instead of silently discarding text.

A posted paste event is not sufficient evidence that the intended field
received text. Wordhand captures the focused Accessibility element and selection
immediately before insertion where the target exposes them. It accepts an
expected UTF-16 cursor advance as acknowledgement, retries a proven no-op once,
and rejects a changed element or unexpected range. Known terminal applications
receive one paste because their Accessibility cursor can stay unchanged after
successful delivery. Some browser, Electron, terminal, and custom-canvas fields
do not expose reliable selection; their compatibility fallback still means a
history status of `inserted` records successful event posting, not verified
field contents. A future history schema should distinguish those two outcomes
explicitly.

Direct Unicode insertion remains a fallback. Copy-only intentionally leaves the
transcript on the clipboard. The last verified insertion keeps enough local
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

The capsule overlay remains the immediate recording and processing surface:
waveform plus cancel while recording, then a clockwise 3×3 perimeter loader
without stage labels while Wordhand transcribes, formats, and inserts. Menu and
window copy must describe recovery actions rather than expose internal errors.

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
  Quality Recordings/             opt-in, automatically expired WAV files
  Models/
```

On the first branded launch, Wordhand copies an existing
`~/Library/Application Support/Parrot` directory into this location through a
staged migration. It never overwrites an existing Wordhand directory and
preserves the legacy directory for rollback.

The final app bundle and bundle identifier will determine the stable TCC
identity. Development builds must not pretend their permission grants prove the
signed release identity works.

`--data-directory` redirects settings, dictionary, and history persistence to
an explicit local directory. It does not isolate global input; development runs
still follow the attended, bounded procedure above.

## Testing strategy

`swift test` is the minimum local gate. CI runs it on a supported macOS runner
and builds the release configuration.

Pure tests cover:

- model registry invariants;
- sanitizer and formatting stages;
- dictionary matching, precedence, Unicode boundaries, and persistence;
- settings defaults, migrations, validation, and atomic-write recovery;
- history insertion, search, retention, and deletion;
- Quality Lab opt-in defaults, WAV encoding, file permissions, record pairing,
  expiry, and deletion;
- insertion routing and clipboard restoration decisions;
- hotkey parsing, serialization, validation, conflicts, and coordinator states;
- rolling-transcript agreement, correction horizon, bounded-window progress,
  ordered chunk forwarding, cancellation, and complete-buffer fallback.

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
