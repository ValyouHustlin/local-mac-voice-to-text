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

## Desktop mastery sequence

Status: crash-safe rolling capture is implemented, its real queued writer is
covered by the process-death oracle, and standard Quit plus system-sleep
interruptions now seal in-flight audio before recovery. An attended installed-
app dictation/Quit/sleep receipt remains before this source checkpoint can be
called daily-runtime verified. The next slice has a checked-in retained-audio
authority oracle; no live partial path is enabled.

Measured daily-use impact keeps the remaining English-first macOS work in this
order:

1. [x] crash-safe rolling capture so acknowledged audio survives process
   failure, sleep interruption, or accidental quit and is recovered to History
   after restart without automatic insertion;
2. [ ] **Deferred at current engine:** safe work-during-speech that lowers
   stop-to-final latency while preserving
   full-buffer authority until retained English fixtures prove beginnings,
   endings, numbers, negations, technical terms, and dictionary spellings;
   a stable-prefix Foundation Models formatting candidate was also rejected
   after two prepared-session probes changed output and slowed median
   formatting by 6.5% and 10.6%, so production retains complete dynamic
   meaning/layout instructions;
3. [ ] local self-learning from explicit corrections and retained recordings
   that suggests improvements without silently changing behavior; the first
   canonical-vocabulary recommendation slice is implemented and isolated-
   verified, and an offline causal replay now proves or rejects a vocabulary
   candidate or evidence-backed pronunciation alias without mutating the live
   recommendation; user-facing pronunciation suggestions, persisted replay
   evidence, model, and configuration suggestions remain;
4. [x] optional application-to-profile routing behind one understandable
   global default;
5. [x] deeper explicit spoken correction and editing commands; exact layout
   commands and one fail-closed earlier-phrase replacement are implemented and
   isolated-verified, while attended natural-command coverage remains;
6. [x] a native evidence-based diagnostics and quality view, using factual
   seven-day activity and exact local evidence counts rather than a health or
   accuracy score;
7. [ ] fresh-Mac onboarding plus the signed, notarized, permission-stable
   updater; the compact readiness window and recoverable local-model
   preparation, fail-closed same-identity update preflight, and nonpublishing
   hardened/notarized artifact builder with pinned Ed25519 manifest
   authentication are source-complete and isolated-verified. Production trust
   remains deliberately unset, so the builder cannot compile or notarize a
   release until key custody is selected. A fresh-account pass, resolved source
   provenance, authenticated public update feed, selected credentials, and attended
   install/update-survival receipt remain.

The first slice stores ordered 16 kHz Float32 frames in owner-only `Pending
Captures` files. A torn last frame is ignored while every earlier complete frame
is recovered bit for bit. The normal stop path still transcribes the complete
in-memory buffer. A restart sends orphaned audio through that same authoritative
full-buffer transcriber, saves it to History as not inserted, and deletes the
journal only after the History commit succeeds. Explicit cancellation deletes
its journal immediately. The background writer now owns explicit contiguous
frame acknowledgements and is the same implementation exercised by the
`SIGKILL` fixture. Standard Quit defers termination until the capture queue is
drained and synchronized. A system-sleep notification seals the same queue and
recovers it without insertion once local transcription can continue. A shared
one-shot capture-stop task prevents Quit or sleep from stopping the audio engine
twice during the 80 ms release tail.

Receipts: `docs/verification/2026-07-30-crash-safe-capture.md` and
`docs/verification/2026-07-30-crash-safe-capture-lifecycle.md`.

The safe work-during-speech entry gate is now executable with `models
authority-compare`. It verifies the retained audio identity, hashes the fixture
definition, alternates paired full-buffer/rolling-final run order, reports
median and p95 stop-to-final latency, and rejects a comparison if any run loses
a protected span or regresses word or character error rate. The first
checked-in English fixture covers both boundaries, a decimal, a negation,
technical terms, and a dictionary-conditioned name. Its four balanced paired
Large v3 runs produced identical transcripts and passed the control-equivalence
gate. Their median times were equal within 0.1 ms, so this is not a latency win
and does not authorize an incremental candidate. Runtime remains unchanged.

The corpus now includes a 49.26-second retained fixture that crosses both the
20- and 40-second rolling boundaries. One fail-closed script runs the short and
long cases and emits an aggregate JSON decision. Two balanced paired Large v3
runs per fixture preserved every protected span with identical baseline/control
transcripts. The long control was slightly slower (6.278 versus 6.274 seconds
median stop-to-final), confirming again that discarded rolling work has no
daily-use value. Stage provenance then measured the same result more precisely:
the control completed 11.48–11.66 seconds of inference across ten pre-release
decodes, reused zero samples, waited about 10 ms for cancellation, then spent
about 2.42 seconds on the primary, 1.21 on the independent tail audit, and 2.65
on the prompt-free full retry.

The ambiguity gate is now implemented before the candidate. A 53.71-second
public retained fixture protects the same six-word anchor exactly twice, and
Large v3 preserved both occurrences plus every existing boundary and semantic
check in paired full-buffer/control runs. The pure composer requires matching
session and audio-prefix identities, valid overlapping sample coverage, one
unique normalized overlap of at least six words, and an explicit integrity
approval. Every mismatch returns a named full-buffer fallback reason. It is not
wired into live capture.

The first cumulative-prefix candidate is implemented only in the offline
authority harness and rejected for daily runtime. Large v3 produced too few
coarse segments to certify a prefix, and its word timestamps sometimes exceeded
the supplied snapshot duration. Text-only successive agreement did certify a
prefix, but a 12-second-overlapping suffix did not reproduce one exact unique
six-word boundary. Every retained run therefore failed closed to the complete
buffer with zero reused samples. Completeness passed, but long medians regressed
from 6.291 to 8.732 seconds and from 4.710 to 7.322 seconds. The corpus now exits
nonzero unless a long run actually composes with nonzero reuse and improves
median latency.

Do not iterate this boundary again in the same lead context. The next safe
work-during-speech attempt needs a fresh architecture decision about a
decoder-native cache/state API or a deterministic audio-boundary alignment
oracle; textual splice heuristics remain rejected. Daily runtime is unchanged.

Receipts: `docs/verification/2026-07-30-completeness-latency-oracle.md` and
`docs/verification/2026-07-30-overlap-composition-oracle.md` and
`docs/verification/2026-07-30-cumulative-prefix-candidate.md`.

The fresh-context non-splice attempt used exact Core ML tensor memoization
through WhisperKit's public feature and encoder seams. It preserved the normal
full-buffer decoder, tail audit, integrity selector, and prompt-free recovery.
Every corpus transcript and protected check passed. Median stop-to-final
improved 23.2% on the 49.26-second fixture, but only 9.6% on the 53.71-second
fixture; the locked bar required 15% on both. The short fixture stayed within
its 100 ms ceiling. The gate correctly exited nonzero, so this candidate also
remains offline-only.

Safe work-during-speech is now deferred at the pinned engine boundary rather
than left open to more splice/cache variants. Reopen it only for a decoder-native
incremental API or a design with a predeclared, materially stronger oracle.

Live metadata then showed 52 retained recordings but zero explicit corrected
references, so pronunciation/model/configuration suggestions remain deferred
instead of being inferred from synthetic yield. The stronger measured issue was
12 full-retry tail recoveries averaging 63.35 seconds of audio and 7.75 seconds
of transcription. `models tail-window-compare` now isolates a fixed 20s/30s
tail-context experiment with shared primary and full-retry decodes, balanced
audit order, transcript-free exact hashes, and the existing protected fixture
gate. The 49.26-second fixture preserved exact text and all six protected
categories, but 30 seconds eliminated no retries and worsened modeled median
stop-to-final from 6.401 to 7.302 seconds. On the shortest real retained
recovery it avoided both retries and modeled 5.371 versus 6.561 seconds, but
both candidate hashes differed from the deterministic 20-second authority.
The oracle rejected the shortcut and runtime remains unchanged.

Subsequent live metadata exposed a higher-priority loss case: one 27.79-second
capture with 97.3% active audio, 0.0175 RMS, and a 0.224 peak produced zero
primary and final words. The installed build returned to idle without History,
Quality Lab, or insertion output. The source path now treats an empty active-
audio decode as a failure rather than success. It performs one prompt-free
complete-buffer retry; a recovered result continues through the authoritative
History-before-insertion path. If the retry is still empty, or formatting erases
nonempty recognition output, the menu reports that the recording was kept and
the crash journal remains byte-exact for restart recovery. Quiet no-speech
captures skip the retry and discard their journals. Cleanup failure remains
visible, whitespace-only formatting cannot be inserted, and one repeatedly
empty oldest journal no longer blocks later startup recoveries.

The deterministic restart oracle reopens the real append journal after an empty
decode and preserves exact Float32 beginning, ending, count, and bit patterns.
A separate ordered-runner oracle preserves the failed oldest item, completes
later recoveries, and only then resurfaces the kept-recording failure.
A two-run cached Turbo replay of the protected 12.57-second English fixture kept
both arms byte-identical and passed every beginning, ending, number, negation,
technical-term, and dictionary-spelling check. The installed build remains
unchanged, so natural empty-recovery behavior is not yet a live product claim.

The first local self-learning slice is implemented without automatic behavior
changes. Two distinct explicit corrections with their paired retained
recordings can produce one conservative canonical-term recommendation in
History. The oracle requires one bounded lexical change in each record, proves
the missed source words were present in the raw decode, rejects formatting,
semantic, number, negation, common-spelling, multi-edit, conflicting, and
already-covered cases, and emits a deterministic suggestion only at two-record
support. Missing or pruned audio yields no suggestion.

The contextual action appears only on the newest supporting History record.
Review does not mutate state; the user must confirm `Add to Vocabulary`.
Acceptance stores `term -> term`, immediately updates decode-time conditioning,
creates no pronunciation alias or broad post-decode substitution, and removes
the now-covered suggestion. An isolated native AppKit render confirmed the
single action fits the existing History detail pane.

The candidate-vs-corpus replay slice is now executable as an explicit offline
Quality Lab report. It requires two distinct supporting recordings, one or more
unrelated controls, four balanced paired repetitions, repeatable strict source
improvement, exact canonical spelling, protected-content preservation, zero
per-run and aggregate accuracy regression, stable exact-match count, and no
material latency regression. It uses one bounded cached-model-only worker,
receives the private candidate through stdin, emits no transcript text, and
writes no user state.

The tightened canonical receipt still improved word edits from 60 to 36 and
character edits from 240 to 204 using the baseline processor in both arms, but
candidate decode time rose from 44.679 to 54.753 seconds. The oracle rejected
promotion for latency.

Pronunciation replay now requires two repeated explicit `heard -> canonical`
corrections, an already-enabled canonical self-entry, one unrelated control,
and all six live-baseline/priority-control/alias orders. Prompt semantics must
match except for exactly one requested pronunciation guide, and no scored arm
uses candidate deterministic cleanup. The isolated alias receipt was rejected:
both controls already emitted the canonical name, causal word edits stayed
0 to 0, and matched-control decode time rose from 18.034 to 21.222 seconds.
No behavior or replay verdict is persisted. The next learning slice should wait
for real corrected-corpus yield before exposing pronunciation suggestions or
background evaluation. Model or configuration suggestions remain behind
larger-corpus stability gates.

Receipt:
`docs/verification/2026-07-30-exact-inference-cache-candidate.md` and
`docs/verification/2026-07-30-canonical-vocabulary-suggestions.md` and
`docs/verification/2026-07-30-vocabulary-causal-replay.md` and
`docs/verification/2026-07-30-pronunciation-alias-replay.md` and
`docs/verification/2026-07-30-tail-window-oracle.md`.

Application-specific writing styles are now an optional extension of the one
global default. Rules match exact bundle identifiers only. The target, resolved
style, route source, and performance mode are captured once at dictation start
and remain authoritative through prewarming, formatting, History, and private
diagnostics; app switches and Settings edits affect only the next dictation.
Unknown recovery targets and ambiguous persisted rules fail safe to the global
default. A native AppKit render confirmed the complete control fits the
existing Writing Style card without hiding the default.

Receipt:
`docs/verification/2026-07-30-application-style-routing.md`.

Fresh bundled installs now open one compact welcome window that explains the
Control-Space gesture, reports Accessibility, Input Monitoring, Microphone, and
local-model readiness separately, and requires explicit actions for every
permission. Merely presenting the window never triggers a system permission
prompt, and startup does not attempt the global hotkey tap until Accessibility
and Input Monitoring are ready. The completion marker is persisted only after
all four checks are live; closing early leaves onboarding pending. Existing
settings files default to the completed marker so an upgrade does not
unexpectedly reopen onboarding.

Local model warmup now has Preparing, Ready, and Unavailable states in both
Welcome and Settings. A transient failure exposes one bounded `Try Again`
action, and repeated clicks cannot start concurrent retries. Runtime still
opens the complete cached model with network fallback only when needed; no
audio or transcript content is transmitted.

Interrupted model downloads no longer enter an endless generic retry loop.
Wordhand validates the selected Core ML cache's JSON and compiled-model
structure before loading it. A structurally incomplete cache becomes one
specific repair state; it is never moved automatically. One explicit
`Repair Model` action atomically moves only that model into a hidden,
app-owned quarantine and starts one clean replacement preparation. Collision
or move failure preserves the original bytes and permits one bounded retry.
Quarantined bytes survive failed replacement attempts and are removed only
after the selected replacement is fully ready; another model's quarantine is
never touched. The real retained English corpus reconfirmed that the installed
Large v3 cache is accepted and remains network-disabled.

Receipt: `docs/verification/2026-07-30-model-cache-repair.md`.

The app replacement path now stages and authenticates the candidate before
stopping Wordhand or moving the installed app. Both plist and signed bundle
identifiers must match the channel. An update must also preserve the installed
Team ID and exact designated signing requirement. Release updates are confined
to `/Applications/Wordhand.app`; a fresh release cannot claim update continuity
and must arrive through the future notarized distribution path. Development
keeps its separate identity and allows a first local install, but a later
ad-hoc rebuild with a changed code requirement fails rather than silently
resetting privacy grants.

The inherited tag-triggered unsigned command-line publisher is now removed.
The legacy network installer exits before downloading or mutating anything.
A separate nonpublishing builder requires one explicit Developer ID identity,
expected Team ID, notary profile, version, build number, and exact clean source
commit. It builds only the release app identity with hardened runtime, a secure
timestamp, and the microphone entitlement; notarizes and staples the app and
disk image; requires Gatekeeper acceptance; verifies the disk image contains
only `Wordhand.app` and the `/Applications` convenience link; and emits the
final bytes with a local integrity manifest. It cannot upload, publish, install,
open, or discover credentials.

This quarantines the unsafe path without pretending the public channel exists.
The adjacent manifest is not yet independently authenticated, the inherited
source provenance remains unresolved, no Developer ID certificate or notary
profile has been selected, and Apple service acceptance has not been exercised.
Those remain shipping gates.

Receipt:
`docs/verification/2026-07-30-first-run-readiness.md` and
`docs/verification/2026-07-30-update-identity-preflight.md` and
`docs/verification/2026-07-30-release-distribution-quarantine.md`.

The first deeper spoken-editing slice adds deterministic `command new line` and
`command new paragraph` without widening into destructive selection or
document editing. A command must be an exact punctuation-delimited clause with
dictated content on both sides; unprefixed, quoted, leading, trailing, or
question uses remain literal. Collision-free protected tokens cross the local
formatter only when each survives exactly once, in order, in its anchored
segment, with no invented marker; otherwise Wordhand formats the protected
source fallback and restores every boundary. Unrelated formatter whitespace is
unchanged.

Measurement rejected two nicer-sounding grammars. Bare `new line` decoded
reliably but was indistinguishable from semantic speech, while `Wordhand new
line` decoded as `word and new line`. A fixed Samantha utterance using
`command new line` decoded exactly through cached Whisper Large v3. The
opt-in end-to-end receipt drove it through the real model and formatted
TextEdit pipeline to one exact line break and one exact paragraph break. This
is synthetic-voice evidence, not an attended natural-dictation claim.

Receipt:
`docs/verification/2026-07-30-spoken-layout-commands.md`.

The bounded earlier-phrase replacement slice now uses the reserved terminal
grammar `command correction, replace <old> with <new>`. `Wordhand correction`
was rejected after Large v3 decoded it as `word and correction`; the selected
namespace survived multiple fixed synthetic utterances while presenting less
literal collision surface than bare `command replace`.

The pure engine accepts only one standalone terminal command, one `with`
delimiter, 1–8 bounded lexical tokens on each side, and exactly one
case-insensitive token-bounded match in the already-dictated body. It never
fuzzy-matches or reads the surrounding document. Missing, repeated, malformed,
embedded, quoted, question, oversized, or nonterminal commands preserve the
literal cleaned transcript and bypass every formatter. After successful
insertion, a menu-bar notice says the correction was not applied and the text
was preserved; the visible menu-bar item carries that notice even if History
status bookkeeping fails, while private diagnostics retain only the text-free
rejection enum.

Three identity-bound public Samantha fixtures cover one unique replacement,
one repeated-target rejection, and one semantic-discussion rejection. Four
cached Large v3 full-buffer replays per fixture produced the exact bound decode
and expected processed hash, and the real CLI formatter matched all three.
This is retained synthetic namespace and collision evidence, not natural-voice
or field-delivery proof.

Receipt:
`docs/verification/2026-07-30-spoken-replacement-command.md`.

The next explicit editing slice reuses the same fail-closed namespace for
omitted words: `command correction, insert <new> after <anchor>`. It adds only
after one exact, unique, token-bounded anchor in the current dictation and
cannot delete or replace body text. Repeated, missing, subword, decimal,
domain-token, already-present, malformed, quoted, question, oversized, or
nonterminal commands remain literal and bypass formatting. One retained
Samantha fixture decoded the complete namespace, anchor, beginning, and ending
identically in four cached Large v3 runs, then both Casual and the real local
Formatted path produced the bound additive edit. This remains synthetic-voice,
not attended natural-command evidence.

Receipt:
`docs/verification/2026-07-30-spoken-insertion-command.md`.

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

The repaired installed-app checkpoint
`docs/verification/2026-07-29-three-target-checkpoint.md` preserved all five
seeded terms in one accepted Chrome run, but identical audio still produced
`Cloudware`, `Whisperkid`, and `Tailskill` in TextEdit or VS Code. The
three-target accuracy exit receipt therefore remains open.

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
The forced Secure Input receipt plus live acknowledgement/retry/undo receipts
remain open.

Goal: make insertion work in apps that reject synthetic Unicode input without
destroying the user's clipboard.

- [x] Add paste as the default mode.
- [x] Snapshot and conditionally restore all pasteboard item types.
- [x] Do not overwrite clipboard changes made by another app during insertion.
- [x] Keep direct Unicode as a fallback and add copy-only mode.
- [x] Detect Secure Input before clipboard mutation and surface the failure.
- [x] Harden the first post-launch paste with a 120 ms pasteboard settle
  (40 ms thereafter), explicit four-event Command-V chord, and cursor
  acknowledgement where Accessibility exposes a selection.
- [x] Retry exactly once only after a reliable editor field proves the paste
  was a no-op; never retry from an unchanged terminal Accessibility cursor.
- [x] Add an immediate guarded undo/revert action for the last verified
  insertion; refuse if focus or the cursor changed.
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

The 2026-07-29 repaired-build checkpoint reconfirmed insertion into TextEdit, a
focused Chrome textarea, and a VS Code untitled editor. It also found a new
focus-race defect: an advertising iframe can take focus during recording,
causing the intended textarea to remain empty while the paste event is still
recorded as successful. Receipt:
`docs/verification/2026-07-29-three-target-checkpoint.md`.

The cold-start hardening is implemented and fake-backed paths remain green, but
the exact first transcription after a new installed-app launch still needs an
attended cursor-target receipt. Do not claim that symptom closed from event
posting alone.

The 2026-07-29 acknowledgement slice adds fake-backed no-op retry, changed-focus
failure, and safe range-only undo. It does not claim the first-paste symptom is
closed until the installed app is observed in native, browser, and Electron
targets. Receipt: `docs/verification/2026-07-29-quality-lab-insertion.md`.

The 2026-07-29 Ghostty regression showed that an unchanged terminal
Accessibility cursor is not proof of a failed paste. Known terminals now
receive exactly one paste while reliable editor surfaces keep their verified
single retry. Build 13 is installed and fake-backed; the attended Ghostty
receipt remains open. Receipt:
`docs/verification/2026-07-29-terminal-paste-regression.md`.

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
2. [x] explicit spoken self-corrections plus an accuracy-first Maximum
   Performance mode with formatter prewarming and authoritative full-buffer
   transcription;
3. onboarding and model-download recovery; permission repair now distinguishes
   Microphone, Input Monitoring, and Accessibility, while the broader
   fresh-account onboarding flow remains;
4. [x] first app-aware AI/coding profile; prose, chat, and code-comment
   specialization remains;
5. [x] guarded undo/revert of the last verified insertion;
6. [x] private Quality Lab audio retention for local accuracy evaluation;
7. text snippets and explicit voice commands;
8. multilingual selection and language auto-detect.

Why this order: formatting and recovery affect nearly every dictation. App-aware
output and editing commands save repeated cleanup. Multilingual and streaming
are valuable only after the core insertion path is trustworthy and measured.

All processing remains local. App-aware behavior may use the frontmost bundle
identifier and text-field role, but must not transmit or silently store
surrounding document content.

Exit receipts are defined per slice before implementation and include both unit
checks and the real affected flow.

### Private Quality Lab checkpoint

Status: implementation and isolated storage verification complete. Natural
dictation capture is intentionally deferred while Aaron is working. Aaron's
local profile remains opted into seven-day retention; the public default
remains off.

- [x] Keep public/fresh-install audio retention off by default.
- [x] Add a visible Settings toggle with 1, 3, 7, 14, and 30-day expiry choices.
- [x] Pair each WAV to the matching transcript-history UUID without duplicating
  transcript text into a second manifest.
- [x] Restrict the directory to `0700` and WAV files to `0600`.
- [x] Prune expired recordings at startup and after each retained capture.
- [x] Add a 250 MB–10 GB aggregate recording-storage setting, default it to
  2 GB, and prune the oldest WAVs immediately after startup, a limit change, or
  a retained capture.
- [x] Delete paired audio with one history record and delete all retained audio
  when history is cleared or the Settings action is confirmed.
- [x] Add local CLI status, enable, disable, and confirmed clear actions.
- [x] Keep all audio local; add no cloud, sync, analytics, or training job.
- [x] Add `Improve Last Transcript Accuracy…` in the menu bar and an editable
  corrected-reference action in History, persisted in the matching history row.
- [x] Migrate existing version-one history databases in place without losing
  records.
- [x] Build a local-only evaluator that pairs corrected history references with
  their retained WAVs, compares cached models by normalized word/spelling error,
  exact matches, transcription latency, and real-time factor, and never prints
  transcript content.
- [x] Run each compared model in a bounded isolated process so Core ML resources
  are released between models and a stalled warmup cannot run indefinitely.
- [x] Refuse implicit model downloads and report missing labels or paired audio
  with the exact corrective action.
- [ ] Observe one opted-in natural dictation produce a paired WAV after Aaron is
  available for attended audio verification.

Receipts: `docs/verification/2026-07-29-quality-lab-insertion.md` and
`docs/verification/2026-07-29-quality-corrections-storage.md` and
`docs/verification/2026-07-29-quality-evaluator.md`.

### Private operational diagnostics checkpoint

Status: implementation, isolated verification, and installed-app startup
receipt complete. Natural dictation-stage data will accumulate through normal
use.

- [x] Record structured app, permission, hotkey, model, capture, transcription,
  processing, history, insertion, cancellation, and failure events.
- [x] Correlate every dictation stage with a stable local UUID.
- [x] Summarize audio signal health without writing samples.
- [x] Record tail-audit and tail-recovery outcomes and surface a `Tail
  recovered` badge in History.
- [x] Rotate logs daily, retain 90 days, enforce a strict 250 MB aggregate
  ceiling, and keep directory/file permissions at `0700`/`0600`.
- [x] Reject known transcript, prompt, dictionary, and audio payload keys.
- [x] Tolerate malformed JSONL lines without losing the healthy report.
- [x] Add an hourly local heartbeat with uptime, readiness, power, and thermal
  state so long unattended runs leave liveness evidence.
- [x] Add local status, report, export, and confirmed clear CLI commands.
- [x] Add Settings actions to reveal diagnostics and copy a report without
  blocking the UI while a large archive is read.
- [x] Add one native Recent activity card with unique completed-dictation
  count, failure-event count, exact median completion time, unique recovered-
  ending count, corrected-reference count, and the exact corrected/audio pair
  count.
- [x] Keep the seven-day summary read-only and non-persisted, exclude future
  and out-of-window events, and show an unavailable state instead of false
  zeros when any local evidence store cannot be read.
- [x] Cancel stale refresh work and gate publication by generation so a slow
  older read cannot replace newer evidence.
- [x] Render and inspect the loaded card at the minimum Settings content width.
- [x] Keep the feature entirely local with no analytics or upload path.
- [x] Observe the installed app write startup, permission, hotkey, and warmup
  events without exercising microphone or insertion.

Receipts: `docs/verification/2026-07-30-operational-diagnostics.md` and
`docs/verification/2026-07-30-recent-activity.md`.

### Flow feedback and app-aware formatting checkpoint

Status: complete for the second vertical slice.

- [x] Add restrained local start, stop, and cancel tones with a Settings toggle.
- [x] Pre-prepare cue audio, request accepted-start feedback before capture
  startup, and decouple finish feedback from recovery-journal drain latency.
- [x] Replace the passive six-bar indicator with an expressive eleven-bar
  waveform and a modern matte treatment.
- [x] Remove stage text and the double-shadow/tech-border treatment; use a
  single minimal capsule and clockwise 3×3 rounded-square processing loader.
- [x] Add a visual-only overlay preview command that uses no microphone,
  playback, global event tap, or synthetic insertion.
- [x] Keep the overlay on the display containing the pointer.
- [x] Add an accessible X that discards capture/transcription before insertion.
- [x] Increase the X click target from 20 × 20 to 28 × 28 points without
  increasing the 10-point glyph.
- [x] Reset tap-toggle routing on cancellation so the next tap starts normally.
- [x] Replace inferred Automatic behavior with four explicit choices: Casual,
  Formatted, Professional, and AI Communication.
- [x] Keep the profiles application-neutral so Terminal, Ghostty, coding tools,
  browsers, native apps, and Electron apps receive the same selected behavior.
- [x] Use Apple's on-device system language model when available, with safe
  output bounds, an eight-second deadline, one conservative retry, and
  deterministic local fallback.
- [x] Reject rewrites that change speaker perspective, actor/recipient roles,
  modality, uncertainty, technical tokens, numbers, or negated constraints.
- [x] Make AI Communication choose structure proportionally: preserve connected
  reasoning as prose, reserve bullets for parallel items, numbered steps for
  ordered sequences, and headings for genuinely complex execution requests.
- [x] Keep surrounding application text out of the formatter.
- [x] Keep formatting instructions, user vocabulary, audio, and transcript
  content on-device with no cloud fallback.
- [x] Remove unambiguous hesitation sounds (`um`, `uh`, `erm`, and `hmm`,
  including stretched forms) deterministically in every writing style after
  dictionary substitution. The isolated CLI receipt transformed
  `Um, I, uh, think we should erm ship this. Hmm... Please do.` into
  `I think we should ship this. Please do.` without launching audio or global
  input.

Receipts: `docs/verification/2026-07-28-flow-formatting.md` and
`docs/verification/2026-07-29-writing-modes.md` and
`docs/verification/2026-07-29-adaptive-ai-relaunch.md`.

### Decode-time vocabulary checkpoint

Status: implementation and controlled benchmark complete; live correction
gesture remains.

- [x] Feed enabled canonical dictionary spellings into WhisperKit at decode
  time instead of relying only on post-hoc replacement.
- [x] Keep post-hoc `heard as -> replace with` matching as the fallback.
- [x] Ship starter vocabulary as versioned editable JSON, not source constants.
- [x] Merge upgraded starter terms without overwriting user entries or
  resurrecting a user-deleted term at the same seed version.
- [x] Apply dictionary edits to both paths without restarting Wordhand.
- [x] Keep dictionary content local to Application Support and in-memory prompt
  tokens.
- [x] Upgrade to the official Argmax OSS/WhisperKit 1.0 dependency line.
- [x] Guard Large v3 prompt prefill from WhisperKit's premature end-token stop.
- [x] Prioritize custom corrections and cap each decode prompt at 24 terms.
- [x] Place highest-priority terms nearest Whisper's decode boundary and repeat
  only the strongest four once; an identical fixture changed `Valio` to
  `Valyou` without a dangerous global `value -> Valyou` replacement.
- [x] Force local dictionary files to owner-only `0600` permissions.
- [x] Pass the five-term identical-audio before/after benchmark (`2/5` to
  `5/5` exact terms).
- [x] Condition decode-time recognition on editable pronunciation aliases, not
  canonical spellings alone, while retaining the same rows as post-hoc
  fallback corrections.
- [x] Pass an identical-audio pronunciation benchmark for
  `Aaron Browne-Moore` and `tmux` (`2/4` to `4/4` exact occurrences).
- [ ] Drive a new correction through the live Dictionary UI, then observe the
  next transcription use it.

Receipts: `docs/verification/2026-07-28-decode-vocabulary.md` and
`docs/verification/2026-07-29-pronunciation-aliases.md`.

### Transcript integrity regression checkpoint

Status: complete for the reported Ghostty and retained long-form regressions.
Development build 18 is installed; broader target-specific compatibility gates
remain in their phases.

- [x] Detect a truncated vocabulary term leaking at the beginning of a
  conditioned transcript without globally stripping legitimate names.
- [x] Detect an unpunctuated ending while the final two seconds of captured
  audio remain active.
- [x] Use decoded segment timing as an additional signal for punctuation that
  appears complete before sustained later speech, without letting timing
  suppress the proven unpunctuated-tail safeguard.
- [x] For a tail issue longer than 20 seconds, decode only the final
  20 seconds first and append recovered text only after one unique normalized
  overlap of at least four words.
- [x] Independently audit the final 20 seconds of every 30-second-or-longer
  recording with late speech, even when Whisper reports complete segment timing
  and terminal punctuation.
- [x] Fall back to the prompt-free full-buffer recovery when the short tail
  decode fails, has no safe overlap, has an ambiguous repeated overlap, or
  exposes unrepresented words before an apparently covered suffix.
- [x] Require a long-form full recovery to be materially longer and lexically
  aligned so an equal-length unconditioned retry cannot damage dictionary terms.
- [x] Keep tail recovery available when no vocabulary prompt was applied; a
  full prompt-free retry remains limited to suspicious conditioned results.
- [x] Select the clean retry only when it removes the prompt artifact without
  materially losing words or restores an equal-or-longer complete ending.
- [x] Preserve the primary result when the recovery decode fails or is not
  demonstrably better.
- [x] Compare recording wall time with captured sample duration and refuse to
  insert when the captured buffer is more than 750 ms short.
- [x] Cover the observed `Aaron Browne-` prefix shape, active-audio cutoff,
  legitimate-name subject, silent tail, retry selection, and capture-gap
  refusal with deterministic tests.
- [x] Install the corrected development build without registering a login item
  and confirm Microphone, Input Monitoring, Accessibility, and Control-Space
  readiness.
- [x] Observe short and 60-second natural dictations preserve both their first
  and final clauses without a name prefix.
- [x] Fix the receipt's lowercase-after-filler edge and malformed web-scheme
  slashes, then install build 15 with permissions intact.
- [x] Remove the retired plain build from Applications and preserve it as a
  non-launchable rollback backup.
- [x] Replay the exact retained 28.79-second cutoff recording five times through
  both build 15 and the new path. All ten runs retained the known final sentence;
  median transcription time improved from 5.681 to 4.542 seconds.
- [x] Install development build 16 with the stable local signing identity,
  confirm all three privacy permissions plus Control-Space remain ready, and
  relaunch the installed app without exercising microphone or insertion paths.
- [x] Reproduce a 65.09-second end truncation from its retained WAV, recover the
  missing ending through the independent tail audit, and install build 18 with
  permissions plus Control-Space still ready.

Receipts: `docs/verification/2026-07-29-transcription-integrity-regressions.md`,
`docs/verification/2026-07-29-tail-recovery-speed.md`, and
`docs/verification/2026-07-29-independent-tail-audit.md`.

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

### Global input safety checkpoint

Status: implementation and isolated verification complete. Real global-input
execution is prohibited for agent lanes on Aaron's shared Mac.

- [x] Add `WORDHAND_SAFE=1` startup refusal before model or runtime setup.
- [x] Put event-tap creation behind an injected `HotkeyTapInstalling` adapter.
- [x] Put Unicode and paste event posting behind an injected
  `TextEventPosting` adapter.
- [x] Test both adapters with fakes that install or post no global events.
- [x] Require explicit opt-in plus a 1–30 second self-termination timeout for
  deliberate development tap tests.
- [x] Document `/usr/bin/pkill -x wordhand` as the immediate kill path.
- [x] Record the incident and no-live-run development rule durably.

Receipt: `docs/verification/2026-07-28-global-input-safety.md`.

### Accuracy and latency checkpoint

Status: complete for the model/capture upgrade. The rolling engine is retained
as an isolated offline experiment, but daily runtime uses the authoritative
single full-buffer path after a natural dictation exposed dropped boundary
speech. Its attended microphone latency receipt remains open.

- [x] Make optimized Whisper Large v3 (626 MB) the accuracy-first default.
- [x] Add a repeatable same-audio model benchmark command.
- [x] Expose model choice and honest relaunch behavior in Settings.
- [x] Reduce microphone tap size from 4096 to 1024 frames.
- [x] Retain an 80 ms capture tail after shortcut release.
- [x] Benchmark Base and Large v3 on the same 11.00-second fixture.
- [x] Keep Adaptive as the public default single-batch path.
- [x] Add a user-selected Maximum mode that prewarms the local formatter; its
  rolling experiment decodes ordered audio chunks every two seconds offline.
- [x] Stabilize successive rolling results while keeping the last two segments
  revisable for corrections.
- [x] Bound the working decode window at 20 seconds and retain the complete
  capture as a no-data-loss fallback.
- [x] Make a silence-aware full-buffer decode authoritative on every Maximum
  mode release; never insert the rolling window composite.
- [x] Add a no-microphone `models benchmark --streaming` replay path that
  exercises rolling decode plus release finalization against a local file.
- [x] Add a checked-in retained English fixture and paired completeness oracle
  that binds expected audio/fixture hashes, validates all six protected
  categories plus boundary placement/reference truth, alternates balanced run
  order, reports median/p95
  stop-to-final latency, and rejects protected-content or aggregate-accuracy
  regressions.
- [x] Cancel stale in-flight partial work at release before the authoritative
  full-buffer decode and cache dictionary prompt tokenization until vocabulary
  changes.
- [x] Preserve identical text on the 11.00-second fixture while one measured
  Large v3 Turbo rolling run moves from 2.167 seconds to 1.556 seconds
  stop-to-final. This is an isolated benchmark, not a natural-voice claim.
- [x] Disable rolling previews in the daily runtime after measuring that
  discarding them for an authoritative full decode only increased release
  latency.
- [ ] Re-enable live partial decoding only after it produces visible partial
  value, passes the checked-in authority oracle across a broader retained
  corpus, and survives attended short/long natural dictation.
- [x] Enable WhisperKit silence-aware chunking for recordings longer than one
  model window so long batch and streaming-fallback decodes split at pauses and
  use the Mac's concurrent decode workers.
- [x] Verify the identical 61.72-second fixture improves from 7.156 seconds to
  4.778 seconds and retains the final clause dropped by fixed-window decoding.
- [ ] Measure stop-to-insertion latency for short and four-minute natural
  dictation after Aaron is available for attended microphone verification.

Receipts: `docs/verification/2026-07-28-accuracy-paste.md`,
`docs/verification/2026-07-29-corrections-streaming.md`,
`docs/verification/2026-07-29-long-dictation-vad.md`, and
`docs/verification/2026-07-29-streaming-tail-overlay.md`, and
`docs/verification/2026-07-30-completeness-latency-oracle.md`.

### Spoken corrections and Maximum Performance checkpoint

Status: implementation, offline verification, and signed build 10 installation
complete. Natural-voice latency and tail receipts remain open.

- [x] Resolve explicit `wait, no`, `I meant`, `make that`, `correction`,
  `scratch that`, and `start over` repairs before formatting.
- [x] Remove safe immediate false starts without deleting meaningful
  repetition.
- [x] Preserve semantic `no` and ordinary `I meant` statements.
- [x] Keep Whisper Large v3 as the accuracy-first model.
- [x] Add Adaptive and Maximum performance settings with backward-compatible
  persistence and live runtime updates.
- [x] Prewarm the on-device formatter at startup and recording start in
  Maximum mode, with a bounded prepared-session cache.
- [x] Feed captured audio through one ordered stream and prevent release from
  racing another preview decode.
- [x] Use a complete full-buffer decode as the authoritative final result on
  every release, not only after streaming failure.
- [x] Exercise the correction path through the real offline CLI formatter and
  pass the complete 114-test suite, release build, and Thread Sanitizer suite.
- [x] Install signed build 10 with Maximum selected and confirm all three
  privacy permissions plus Control-Space remain ready.
- [ ] Record attended short and long natural-voice receipts without
  interrupting active work.

Receipt: `docs/verification/2026-07-29-corrections-streaming.md`.

## P7: ship quality

Status: in progress; certificate and public-release actions are Aaron-gated.

Goal: install and update like a normal trusted Mac app.

- [x] Produce separate development (`com.valyou.wordhand.dev`) and reserved
  release (`com.valyou.wordhand`) app identities.
- [x] Add a rollback-preserving development installer that cannot register a
  LaunchAgent, login item, or background item.
- [x] Show an inline one-click relaunch action only after a setting that needs
  restart changes; model selection is the current restart-required setting.
- [x] Prefer the standard `/Applications` location, register/import the active
  bundle for Spotlight, and keep rollback apps outside searchable application
  folders so LaunchServices sees one active Wordhand.
- [x] Preserve rollback bundles with a non-launchable `.app-backup` suffix,
  exclude build output from Spotlight, and unregister it so only the installed
  app owns the Wordhand identity.
- [x] Keep UI and shortcuts immediately available during background model
  warmup, and bypass network validation for a complete local model cache.
- [x] Add visible permission status and in-app recovery controls that
  independently verify Microphone, Input Monitoring, and Accessibility.
- [x] Make Settings resizable, remember its frame, and open at a size that
  exposes substantially more controls.
- [x] Support a persistent local Keychain signing identity and warn explicitly
  when an ad-hoc rebuild can invalidate macOS privacy grants.
- [x] Restrict local settings, vocabulary, and history data to the owner.
- [x] Add opt-in, automatically expired, owner-only local Quality Lab audio
  retention while keeping the public default off.
- [x] Select Aaron's stable local development signing identity.
- [ ] Verify two updates of the same installed development identity do not
  produce Background Items or privacy approval prompts.
- Sign with hardened runtime.
- Notarize and staple.
- Package without stripping quarantine.
- Add release CI, checksums, changelog, and rollback instructions.
- [x] Bind exact release-manifest bytes to a canonical Ed25519 signature and a
  production trust anchor compiled into the signed verifier; keep fixture keys
  test-only and fail before app compilation/notarization while production
  trust is unset.
- Resolve upstream license provenance and publish a compatible project license.
- Add an update mechanism whose metadata contains no transcript content.
- Keep release login-item registration intact across update without calling
  unregister/register; fail release if Background Items or privacy prompts
  recur.
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
