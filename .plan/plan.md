# Wordhand product roadmap

This fork is building a full local dictation product for Mac and iPhone, not
preserving upstream's minimal daemon scope. See `docs/architecture.md` for the
product contract and target boundaries.

## Rules for every phase

- End with a usable vertical slice.
- Add an automated check before or with new pure logic.
- Drive the real user flow before calling runtime behavior shipped.
- Record exact verification commands, gestures, targets, observations, and
  measured latency where relevant.
- Keep audio, transcripts, dictionary entries, and history on-device.
- Commit each completed phase. Do not mix unfinished features into a phase
  commit.
- Update this roadmap when evidence changes the order.

## Public checkpoint cadence

Public updates follow product evidence, not a calendar. Each checkpoint groups
three verified daily-use improvements so the post has a meaningful before and
after:

- lead with the competitive problem and the user-visible result;
- show the real Wordhand UI or behavior, never a concept mockup;
- keep the main post focused on the hook and put the repository link in the
  first reply;
- claim only behavior observed in this session;
- do not publish until Aaron explicitly approves the final copy and media.

## Public identity

Status: complete.

The product name is Wordhand. The app, Swift package, executable, module names,
documentation, icon, and repository use one identity. The previous name is
retained only for upstream attribution and automatic user-data migration.

The repository is public source. Upstream currently provides no software
license, so resolving provenance is a release prerequisite before calling the
project open source or encouraging redistribution.

Receipt: `docs/verification/2026-07-28-wordhand-brand.md`.

## P0: ground truth

Status: complete for the initial baseline. Browser end-to-end and LaunchAgent
TCC remain explicit open receipts.

Goal: establish what the current fork actually does on this Mac.

- Build debug and release configurations.
- Run `wordhand doctor` and record TCC state for the exact development binary.
- Warm the recommended model and record model/download behavior.
- Dictate for several minutes through the actual hotkey.
- Exercise one native app, one browser field, and one Electron app.
- Record missed presses, dropped releases, transcript errors, injection
  failures, overlay state errors, and post-release latency.
- Separate product failures from permission identity failures.

Exit receipt: a dated local verification report with observed results and open
defects. A passing build alone does not complete P0.

Receipt: `docs/verification/2026-07-28-baseline.md`.

## P1: foundation and product charter

Status: complete.

Goal: make the codebase safe to grow and stop inherited docs from steering the
fork toward the wrong product.

- Replace the inherited architecture and plan with this fork's product
  contract.
- Add a `WordhandCore` library target and `WordhandCoreTests`.
- Move or wrap model registry and transcript sanitization as pure logic.
- Add versioned settings types with testable storage.
- Put audio capture, transcription, hotkey monitoring, text insertion,
  pasteboard access, filesystem, active-app lookup, and clock behind protocols.
- Add a coordinator state machine exercised with fakes.
- Add macOS CI for `swift test` and release build.
- Preserve the current executable behavior while extracting seams.

Exit receipt:

```text
swift test
swift build -c release
```

Both commands must finish successfully from a clean checkout. The current
daemon must still launch to its permission/model boundary.

Receipt: `docs/verification/2026-07-28-foundation.md`. Local tests, local
release build, live daemon launch, and remote CI all passed on 2026-07-28.

## P2: custom dictionary

Status: in progress. Persistence, hot-reloadable processing, management UI,
latest-transcript action, and phrase preview are implemented. The required
three-target live dictation receipt is still open.

Goal: fix names, acronyms, product terms, and technical language locally.

- Store versioned local dictionary entries.
- Apply deterministic longest-first replacements with Unicode-safe boundaries.
- Add dictionary management UI.
- Add an action from the most recent transcript to create a correction in one
  gesture.
- Show a preview before committing ambiguous replacements.
- Cover precedence, casing, punctuation adjacency, Unicode, persistence,
  deletion, and migration in tests.

Exit receipt: dictate a known failure, add its correction from the latest
transcript, repeat the phrase in three targets, and observe the corrected term.

Partial receipt: `docs/verification/2026-07-28-dictionary.md`.

## P3: transcript history

Status: implementation complete; isolated native UI receipt complete. Fresh
microphone and forced live-insertion exit receipt remains open.

Goal: make every transcript visible and recoverable.

- Save transcript records before insertion.
- Add a searchable native history window with timestamps.
- Support copy, re-insert, create dictionary correction, delete, and clear-all.
- Record raw/final text, model, language, duration, latency, target app, mode,
  and insertion result.
- Add retention and migration behavior.
- Test search, ordering, persistence, retention, deletion, and failed-insertion
  recovery.

Exit receipt: create several transcripts, force one insertion failure, restart
the app, search for the failed transcript, copy it, and re-insert it.

Partial receipt: `docs/verification/2026-07-28-history.md`. The SQLite store,
save-before-insert coordinator path, restart persistence, search, copy,
reinsert, correction prefill, delete, clear-all, Dock reopen behavior, and
native UI were observed with isolated fixture records. A microphone-created
failed record still needs the full native/browser/Electron lane receipt.

## P4: reliable paste and clipboard modes

Status: planned.

Goal: make insertion work in apps that reject synthetic Unicode input without
destroying the user's clipboard.

- Add paste as the default mode.
- Snapshot and conditionally restore all pasteboard item types.
- Do not overwrite clipboard changes made by another app during insertion.
- Keep direct Unicode as a fallback and add copy-only mode.
- Detect or infer secure-input/inaccessible-target failures and surface them.
- Add an immediate undo/revert action for the last insertion.
- Test clipboard races, empty pasteboards, rich content, fallback routing,
  copy-only, and undo state.

Exit receipt: paste into native, browser, and Electron targets while preserving
a preloaded rich clipboard item; verify secure-input failure leaves transcript
recoverable.

## P5: configurable hotkeys

Status: implementation complete for recording shortcuts and Settings UI.
Restart persistence and live rebinding are verified. Three-target dictation
with the rebound shortcut remains open.

Goal: remove the hard dependency on `fn` and support daily workflows.

- [x] Represent bindings as versioned settings with migration from the previous
  key-name-only shape.
- [x] Support push-to-talk and tap-to-start/tap-to-stop recording without
  requiring `fn`.
- [x] Support multiple recording bindings.
- [x] Add native capture/edit UI, validation, duplicate detection, and the known
  macOS Control-Space reservation warning.
- Recover cleanly from missed release, app deactivation, sleep, and settings
  changes during a hold.
- [x] Test parsing, serialization, duplicate conflicts, state edges, and live
  rebinding logic.

Exit receipt: configure a non-`fn` binding, restart, dictate in three targets,
then change the binding while running and observe only the new binding fire.

Partial receipt: `docs/verification/2026-07-28-settings-hotkeys.md`. The native
Settings window, persisted capture, live rebinding, tap toggle behavior, old
binding removal, and menu state were observed in the running app.

## P6: daily-use gap

Status: planned; order must be validated after P0-P5 usage data.

Current ranking:

1. conservative auto-formatting and filler-word cleanup;
2. onboarding, permission repair, and model-download recovery;
3. app-aware formatting for prose, chat, and code-comment contexts;
4. undo/revert of the last insertion if not completed in P4;
5. text snippets and explicit voice commands;
6. multilingual selection and language auto-detect;
7. streaming or partial results where measurements show perceived latency needs
   it.

Why this order: formatting and recovery affect nearly every dictation. App-aware
output and editing commands save repeated cleanup. Multilingual and streaming
are valuable only after the core insertion path is trustworthy and measured.

All processing remains local. App-aware behavior may use the frontmost bundle
identifier and text-field role, but must not transmit or silently store
surrounding document content.

Exit receipts are defined per slice before implementation and include both unit
checks and the real affected flow.

## P7: ship quality

Status: planned; certificate and public-release actions are Aaron-gated.

Goal: install and update like a normal trusted Mac app.

- Produce a stable `.app` bundle and bundle identifier.
- Sign with hardened runtime.
- Notarize and staple.
- Package without stripping quarantine.
- Add release CI, checksums, changelog, and rollback instructions.
- Resolve upstream license provenance and publish a compatible project license.
- Add an update mechanism whose metadata contains no transcript content.
- Test a fresh install, first-run permissions, model failure/retry, login start,
  update, rollback, and uninstall.

Exit receipt: install the notarized artifact on a clean macOS user account,
complete onboarding, dictate into all three target classes, restart, update,
and verify settings/history survive.

## P8: iPhone 17 Pro companion

Status: source foundation complete on `codex/ios17-pro`; iOS build, signing,
device benchmark, and real-field insertion receipt blocked by the absence of
full Xcode and a discoverable iPhone on this Mac.

Goal: remove the remaining reason Aaron needs Wispr Flow by making Wordhand
dictation available in standard iPhone text fields without sending voice or
text off device.

- [x] Add a real iOS host-app and custom-keyboard project structure.
- [x] Keep microphone and model loading out of the keyboard extension.
- [x] Record protected 16 kHz mono audio in the host app.
- [x] Require on-device recognition for the Apple Speech adapter.
- [x] Include the exact WhisperKit Large v3 626 MB accuracy candidate behind
  the same platform-neutral audio-file engine protocol.
- [x] Require explicit selection before WhisperKit may download model assets.
- [x] Process text through the shared core boundary.
- [x] Hand one protected pending draft through an App Group and consume it only
  after keyboard insertion.
- [x] Preserve raw audio, model output, processed output, engine, latency, and
  thermal state locally for same-corpus benchmarking.
- [x] Cover atomic handoff, one-time consumption, stale-draft protection,
  expiry, processing, and local observation persistence with pure tests.
- [ ] Build with the current iOS SDK for an iPhone 17 Pro destination.
- [ ] Select an Apple development team and provision matching App Group
  entitlements.
- [ ] Measure Apple Speech and Whisper Large on the same dictated corpus using
  Instruments for peak memory and Energy/thermal observations.
- [ ] Drive Record, return, and Insert in Messages, Notes, and ChatGPT.

Exit receipt: on Aaron's physical iPhone 17 Pro, dictate the same corpus through
both engines, select the more accurate daily default with measured tradeoffs,
then insert exact observed output into Messages, Notes, and ChatGPT. Record any
iOS app-switch limitation instead of assuming the keyboard can return control.

Implementation and current blockers:
`docs/ios-architecture.md`,
`docs/ios-device-setup.md`, and
`docs/verification/2026-07-28-ios-foundation.md`.

## Decision gates

The lane may implement, test, refactor, commit, and push ordinary changes to
Aaron's fork. Surface before:

- selecting or using a code-signing identity or certificate;
- spending money;
- publishing a public release;
- adding any paid API or service;
- sending audio, transcripts, history, dictionary entries, or surrounding text
  off-device.

Recommended defaults:

- SQLite for searchable transcript history.
- versioned JSON for settings and dictionary until scale or query needs justify
  a database migration.
- paste-first insertion with direct Unicode fallback.
- native AppKit/SwiftUI windows.
- no remote analytics or crash reporting.
