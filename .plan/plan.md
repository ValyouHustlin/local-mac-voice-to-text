# Wordhand product roadmap

This fork is building a full local macOS dictation app, not preserving
upstream's minimal daemon scope. See `docs/architecture.md` for the product
contract and target boundaries.

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

Status: core implementation and native/browser/Electron live receipts complete.
The forced Secure Input receipt and immediate undo/revert remain open.

Goal: make insertion work in apps that reject synthetic Unicode input without
destroying the user's clipboard.

- [x] Add paste as the default mode.
- [x] Snapshot and conditionally restore all pasteboard item types.
- [x] Do not overwrite clipboard changes made by another app during insertion.
- [x] Keep direct Unicode as a fallback and add copy-only mode.
- [x] Detect Secure Input before clipboard mutation and surface the failure.
- Add an immediate undo/revert action for the last insertion.
- [x] Test the clipboard ownership/race policy and live rich-content
  restoration.
- Add adapter contract tests for empty pasteboards, write failures, and
  copy-only behavior when the macOS adapter is extracted into `WordhandMac`.

Exit receipt: paste into native, browser, and Electron targets while preserving
a preloaded rich clipboard item; verify secure-input failure leaves transcript
recoverable.

Partial exit receipt: `docs/verification/2026-07-28-accuracy-paste.md`.
TextEdit, Google Chrome, and Visual Studio Code accepted the complete final
transcript. Chrome and VS Code preserved a preloaded clipboard containing RTF
and both UTF-8/UTF-16 plain text. The Secure Input branch is automated and
implemented but has not been forced in a real password field.

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

Status: in progress. The first app-aware formatting and recording-feedback
checkpoint is implemented and live-verified.

Current ranking:

1. [x] conservative auto-formatting and filler-word cleanup;
2. onboarding, permission repair, and model-download recovery;
3. [x] first app-aware AI/coding profile; prose, chat, and code-comment
   specialization remains;
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

### Flow feedback and app-aware formatting checkpoint

Status: complete for the first vertical slice.

- [x] Add restrained local start, stop, and cancel tones with a Settings toggle.
- [x] Replace the passive six-bar indicator with an expressive eleven-bar
  waveform and a modern matte treatment.
- [x] Keep the overlay on the display containing the pointer.
- [x] Add an accessible X that discards capture/transcription before insertion.
- [x] Reset tap-toggle routing on cancellation so the next tap starts normally.
- [x] Add Automatic, Polished, AI prompt, and Verbatim writing profiles.
- [x] Route Ghostty, terminals, development tools, and AI apps to AI-prompt
  formatting in Automatic mode.
- [x] Use Apple's on-device system language model when available, with safe
  output bounds, a four-second deadline, and deterministic local fallback.
- [x] Keep surrounding application text out of the formatter.

Receipt: `docs/verification/2026-07-28-flow-formatting.md`.

### Application hardening checkpoint

Status: implementation and available live gates complete.

- [x] Prevent duplicate processes from competing for the microphone, global
  shortcut, clipboard, and insertion target.
- [x] Stop and process toggle recordings at ten minutes instead of allowing an
  unbounded in-memory audio buffer.
- [x] Signal active Whisper decoding when a user cancels.
- [x] Reject local model rewrites that drop numbers, technical tokens,
  acronyms, or negated constraints.
- [x] Compile tests and release builds with warnings treated as errors.
- [x] Pass the complete test suite under Thread Sanitizer.
- [x] Build and run the executable under Address Sanitizer.

The 10-minute stop and active Whisper cancellation are covered through
protocol-backed tests. A literal 10-minute microphone wait and a deliberately
long live decode cancellation remain useful soak receipts, not blockers for the
bounded implementation.

Receipt: `docs/verification/2026-07-28-hardening.md`.

### Accuracy and latency checkpoint

Status: complete for the model/capture upgrade; continue measuring Aaron's own
speech.

- [x] Make optimized Whisper Large v3 (626 MB) the accuracy-first default.
- [x] Add a repeatable same-audio model benchmark command.
- [x] Expose model choice and honest relaunch behavior in Settings.
- [x] Reduce microphone tap size from 4096 to 1024 frames.
- [x] Retain an 80 ms capture tail after shortcut release.
- [x] Benchmark Base and Large v3 on the same 11.00-second fixture.
- Keep speculative/partial transcription off by default until Aaron's
  post-release measurements justify a second pipeline or a streaming
  architecture. The measured final pass is currently 0.76–1.06 seconds; a
  naive concurrent preview could delay the authoritative transcript.

Receipt: `docs/verification/2026-07-28-accuracy-paste.md`.

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
