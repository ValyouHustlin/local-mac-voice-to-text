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

Development builds must also never create persistence. They use
`com.valyou.wordhand.dev`, cannot register a LaunchAgent, login item, or
background item, and must never invoke an installer with `--launch-at-login`.
The canonical `com.valyou.wordhand` identity and `SMAppService.mainApp` are
reserved for a deliberately built, Developer-ID-signed release. Release updates
must keep the same identifier, installed path, and signing identity without
unregistering and re-registering the login item. Any update that causes
Background Items or privacy permission re-approval fails the shipping bar.

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

Verified by source inspection and dated receipts through 2026-07-30:

- Swift Package Manager library, executable, and test targets for macOS 14+;
- Argmax OSS/WhisperKit 1.0 transcription with four registered local Whisper
  models; optimized Large v3 (626 MB) is the accuracy-first default;
- `AVAudioEngine` capture converted to 16 kHz mono Float32, using 1024-frame
  input buffers and an 80 ms post-release tail to retain final phonemes;
- owner-only append journals for every active capture, with framed Float32
  checksums, torn-final-frame recovery, exact restart replay through the
  authoritative full-buffer transcriber, and deletion only after History
  commits;
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
  cue audio is decoded and prepared at launch, accepted-start feedback is
  requested before capture-engine startup, and finish feedback is requested
  after the 80 ms tail is secured but before recovery-journal draining; any
  failed recovery preparation or capture start immediately supersedes the
  acknowledgement with the descending failure tone; cancellation retains only
  its own descending cue and never emits the normal finish tone, including an
  X click during the release-tail interval, because a one-shot explicit end
  intent replaces ambiguous UI-state inference;
- four explicit writing profiles: Casual, Formatted, Professional, and AI
  Communication; richer profiles use Apple's on-device system language model
  and fall back to deterministic cleanup when unavailable;
- deterministic spoken-repair handling for explicit phrases such as
  `wait, no`, `I meant`, `make that`, and `scratch that`, while preserving
  ordinary semantic uses of `no` and `I meant`;
- explicit `command new line` and `command new paragraph` commands only when
  they occupy a complete punctuation-delimited clause between dictated
  content; unprefixed, leading, trailing, quoted, or structurally ambiguous
  uses remain literal;
- Adaptive and Maximum processing modes; Maximum keeps the local formatter
  prepared while both daily-runtime modes use authoritative full-buffer
  transcription;
- duplicate-process prevention, a 10-minute recording safety stop, active
  Whisper cancellation, capture-duration integrity checking, selective
  prompt-free tail recovery with a full-buffer fallback, and rewrite validation
  that rejects dropped numbers, technical tokens, or negated constraints;
- persistent custom dictionary with versioned, non-destructive editable
  defaults and immediate correction flow;
- searchable SQLite transcript history with copy, reinsert, dictionary
  correction, corrected-reference labeling, tail-recovery labeling, and
  deletion actions;
- private structured operational diagnostics with daily rotation, 90-day
  retention, a strict 250 MB ceiling, hourly liveness snapshots, local
  report/export commands, and no transcript or audio payload fields;
- opt-in local Quality Lab audio retention with automatic expiry, a selectable
  aggregate storage ceiling, owner-only storage, corrected-reference labeling,
  and a local cached-model evaluator; public installs keep retention disabled by
  default;
- suggestion-only local learning that can recognize the same conservative
  canonical vocabulary correction across two explicitly corrected transcripts
  with retained recordings, show one contextual History action, and update the
  live local vocabulary only after explicit confirmation;
- versioned settings and automatic migration from the legacy product name;
- permission doctor and visible in-app recovery that independently checks
  Microphone, Input Monitoring, and Accessibility instead of reporting a
  false-ready state;
- a stable native application bundle with configurable persistent local code
  signing, isolated development and release identities, release-only native
  login-item registration, standard Applications-folder and Spotlight
  registration, and rollback copies stored outside searchable application
  folders;
- immediate menu, Dock, and shortcut readiness while the selected model warms
  asynchronously from a complete local cache without network validation;
- macOS continuous integration for tests and release builds.

Developer ID signing, hardened runtime, notarization, public packaging, a
fresh-account onboarding pass, and a permission-stable updater remain planned.
Only measured receipts may promote latency or compatibility claims.

## Current delivery state

P0 ground truth and P1 foundation are complete as of 2026-07-28. The package
now has `WordhandCore`, protocol-backed coordinator seams, versioned settings,
deterministic tests across core and macOS adapter targets, and macOS CI. The
current exact count belongs in the latest verification receipt rather than this
long-lived architecture document.

The daily-driver bundle is built by `scripts/build-app.sh` and installed by
`scripts/install-app.sh`. Development is the default channel and produces
`Wordhand Dev.app` with `com.valyou.wordhand.dev`; the release identity
`com.valyou.wordhand` is reserved for a deliberately selected release channel
signed by a Developer ID Application certificate. The development installer
prefers `/Applications`, falls back to `~/Applications` when needed, and never
touches the release app or registers a LaunchAgent, login item, or background
item. It rejects `--launch-at-login`. Only the signed release can expose
`SMAppService.mainApp`, and registration is a user action in Settings rather
than part of the update loop.

This boundary is a shipping requirement. Re-registering a replaced app through
macOS Background Task Management can produce repeated `sfltool` approval
prompts. A release update must preserve the canonical bundle identifier,
installed path, and Developer ID signing identity without unregistering and
re-registering the login item. Any update that causes a Background Items,
Microphone, Input Monitoring, or Accessibility re-approval fails the release
gate. Ad-hoc signing remains the source-build fallback and can change the code
identity on rebuild. A local identity selected once through
`scripts/configure-local-signing.sh` is reused automatically by future
development builds; the file stores only its display name while the private key
stays in Keychain.

The installer keeps rollback bundles under Application Support with a
non-launchable `.app-backup` suffix. The build-output directory carries a
`.metadata_never_index` marker and is explicitly unregistered after
installation.
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
are removed. The cancel glyph remains 10 points while its invisible click target
is 28 × 28 points, giving more tolerance without adding visual weight.
Transcription, local formatting, and insertion use one text-free
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

`wordhand models authority-compare` is the first promotion gate for any future
incremental candidate. It loads one identity-bound retained local audio file
once, applies only the fixture's explicit vocabulary, requires an already
cached model, runs one unmeasured inference pair, and alternates an even number
of paired full-buffer/rolling-final measurements. The JSON report binds the
model, baseline/candidate implementation IDs, decoder configuration ID, audio
SHA-256, fixture SHA-256, vocabulary SHA-256, sample count, and sample rate.
Fixtures missing any required category or exact audio identity fail closed.
Category placement is fixed (`beginning` is a prefix and `ending` is a suffix),
and the fixture reference must itself contain every exact expected occurrence.
Every candidate run must contain exact expected occurrences of protected spans
for the beginning, ending, numbers, negations, technical terms, and dictionary
spellings, and its word and character error rates must be no worse than its
paired full-buffer result. Median and p95 stop-to-final times are reported only
after that comparison; speed cannot override missing or degraded text. A
rejected comparison exits nonzero. The command is offline: it does not download
a model, record, play audio, install an event tap, inspect the clipboard, inject
text, or enable a runtime path.

The public synthetic corpus has a 12.57-second lexical fixture, a 49.26-second
boundary fixture that crosses both the 20- and 40-second rolling windows, and a
53.71-second ambiguity fixture with the same six-word overlap anchor protected
exactly twice. `scripts/test-transcription-authority-corpus.sh` runs each
identity-bound fixture through the same command and emits one aggregate JSON
decision, including per-case transcripts, protected results, and latency. It
proves that the gate catches boundary, duplicate, protected-content, and
overlap-anchor loss and that the current rolling-final control remains
equivalent because it still finishes with a complete-buffer decode. The report
explicitly identifies that control implementation; its PASS cannot authorize
an actual incremental candidate. It does not prove a useful latency improvement
or natural-voice completeness. Runtime promotion additionally requires more
voice/acoustic diversity and attended short/long natural dictation.

The comparison report records authority provenance, not only text and wall
time: completed pre-release decode count/time, cancellation-drain wall time,
reused samples, suffix range, overlap word count, authority path/fallback
reason, and primary/tail-audit/full-retry durations. The current long control
performed ten completed pre-release rolling decodes using 11.48–11.66 seconds
of inference but reused no work. Cancellation drained in about 10 ms. After
release it spent about 2.42 seconds on the primary full decode, 1.21 seconds on
the independent tail audit, and 2.65 seconds on the prompt-free full retry.

The pure promotion gate exists without being connected to daily runtime.
`StreamingAuthorityComposer` accepts a release identity, a stable prefix, and a
suffix result. It requires one session and monotonically released snapshot
generation; identical model, vocabulary SHA-256, decoder configuration, and
English-language provenance; an exact hash match between snapshot audio and the
same prefix of final audio; and continuous sample coverage through the final
sample. Text can be composed only when the longest eligible suffix of the
stable prefix matches from the first word of the overlapping suffix decode,
occurs exactly once in both inputs, and contains at least six normalized words.
Unmatched leading suffix text is never discarded. The caller must then approve
the composed text through the integrity finalizer. Every other outcome names a
complete-buffer fallback. Timestamps establish audio coverage only; they never
authorize word removal.

The first executable cumulative-prefix candidate remains authority-harness-only
and is rejected for runtime promotion. It decodes sample-zero snapshots every
eight audio seconds during a 2x-real-time replay, freezes the last completed
successive-agreement prefix before cancellation, decodes a 12-second-overlapping
suffix after release, and falls back to the complete buffer on every failed
identity, coverage, overlap, suffix, or integrity check. Word-level timestamps
were required because Large v3 exposed only one or two coarse segments across a
49.26-second fixture, but retained replay then exposed timestamp ranges outside
the supplied snapshot and no exact six-word suffix overlap. All candidate runs
therefore stayed `full_buffer_control`, reused zero samples, and were slower
than baseline. The corpus gate now requires at least one composed long run with
nonzero reuse plus a lower long median, so fallback-only completeness exits
nonzero. Daily runtime remains unchanged. See
`docs/verification/2026-07-30-completeness-latency-oracle.md` and
`docs/verification/2026-07-30-overlap-composition-oracle.md` and
`docs/verification/2026-07-30-cumulative-prefix-candidate.md`.

A second and final bounded latency experiment replaced text reuse with exact
Core ML inference memoization. It wraps WhisperKit's public feature-extractor
and audio-encoder seams with session-bounded caches keyed by the complete tensor
data type, shape, strides, and bytes. An entry can be reused only when the
authoritative full-buffer pipeline independently produces an identical tensor;
all decoding, VAD ordering, vocabulary conditioning, tail audit, integrity
selection, and prompt-free recovery remain unchanged. Cache misses are ordinary
inference, and the public/default strategy still bypasses and clears the cache.

The retained corpus proved exact output but rejected daily promotion. The
49.26-second recovery-heavy fixture improved from 6.315 to 4.851 seconds
median (23.2%), while the 53.71-second ambiguity fixture improved from 4.734
to 4.281 seconds (9.6%). The predeclared bar required at least 15% on both long
fixtures; the command therefore exited nonzero. The 12.57-second fixture
improved from 1.427 to 1.410 seconds, within its 100 ms regression ceiling.
Both long fixtures reported deterministic exact feature and encoder hits in
every run, and all protected spans, WER, CER, and integrity outcomes passed.
Because the benefit did not clear the product bar consistently and required
7.97–12.0 seconds of speculative inference during long speech, the experiment
remains offline-only. No current safe work-during-speech candidate is promoted;
the roadmap advances to local self-learning until a decoder-native incremental
API or stronger measured design changes the tradeoff. See
`docs/verification/2026-07-30-exact-inference-cache-candidate.md`.

## Suggestion-only local learning

The first learning slice is deliberately narrower than automatic adaptation.
Wordhand can recommend one canonical vocabulary term only when all of these
local facts agree:

- two distinct History records contain explicit nonempty corrected references;
- both UUIDs still have their opt-in Quality Lab recordings;
- each processed transcript differs from its reference in one bounded lexical
  region, and the raw authoritative decode contains the same missed source
  words;
- both corrections resolve to the same distinctive canonical term;
- the change is not punctuation, capitalization-only, a number, negation,
  modal, common spelling variant, broad rewrite, competing correction, or an
  already represented dictionary term.

Suggestions are recomputed from current History, recordings, and Dictionary
state. Nothing is persisted or mutated by evaluation. Only the newest
supporting History record shows one contextual `Review Suggestion…` action.
Reviewing opens a confirmation; accepting writes `term -> term` through the
existing `DictionaryStore` and live `DictionaryVocabularySource`. That form
conditions local decoding without introducing a global post-decode
pronunciation replacement. Ignoring the action, missing or pruned recordings,
deleted History, evaluator abstention, and ordinary dictation all leave
behavior unchanged.

This is not yet a claim that Wordhand has enough real corrected evidence to
recommend a term for Aaron, nor that a suggested term improves a retained
recording on replay.

`wordhand quality prove-vocabulary` is the offline causal gate for that second
claim. Its private request arrives through stdin so the candidate is absent
from process arguments. One bounded child process loads an already cached
model, makes a byte-stable private copy of History and its WAL without opening
the live SQLite files, and decodes Dictionary without migration. Canonical-term
replay compares baseline with an in-memory `term -> term` candidate in fixed
B/C, C/B, C/B, B/C order. Both arms use the baseline deterministic processor,
so a candidate replacement cannot manufacture a decode-time win. It requires
two distinct supporting recordings, at least one unrelated paired recording,
four complete repetitions per recording, exact canonical spelling in every
supporting candidate result, strict word- and character-edit improvement on at
least three repetitions of each source, no per-run or aggregate corpus
regression, no protected boundary/number/negation/dictionary loss, no exact-
match loss, and no material latency regression. Missing or malformed evidence
is inconclusive; observed harm is rejected.

Schema 2 extends the same gate to pronunciation aliases. The requested
`heardAs -> canonical` pair must already be supported by two explicit retained
History corrections, the canonical self-entry must already be enabled, and the
forms must be a close split/merge spelling with the same initial character and
distinctive canonical orthography such as a hyphen, internal capital, acronym,
or technical punctuation. Ordinary word-for-word edits such as
`Friday -> Monday` and semantic compounds such as `every day -> everyday`
abstain instead of becoming global aliases; supporting those safely requires a
future explicit heard-as correction signal.
Each recording runs all six B/K/A orders: live baseline, a canonical-priority
control, and the alias. Prompt snapshots must prove K and A have identical
canonical terms, ordering, and priority and differ by exactly the requested
pronunciation association. A must beat K to establish alias causality and B
for live safety. Candidate deterministic cleanup is excluded from every scored
arm, and both decisions must prove. Neither result changes History, Dictionary,
Settings, the recommendation UI, or daily transcription.

The transcript-free report contains hashes, aggregate counts, durations, and a
versioned verdict. The public retained fixture proved the mechanism and rejected
the tested name candidate because its accuracy gain cost material decode time.
An isolated pronunciation receipt also rejected the tested alias because both
baseline controls already emitted the canonical spelling, leaving no causal
accuracy gain and a latency regression. The current History suggestion
therefore remains evidence-independent and explicitly confirmed, rather than
implying replay proof. Persisted evidence or background UI evaluation waits for
real corrected-corpus yield. User-facing pronunciation suggestions, model
selection, and configuration suggestions still require their own evidence
gates. See
`docs/verification/2026-07-30-canonical-vocabulary-suggestions.md` and
`docs/verification/2026-07-30-vocabulary-causal-replay.md` and
`docs/verification/2026-07-30-pronunciation-alias-replay.md`.

The authoritative decode has layered local integrity checks. First, the coordinator
compares the monotonic recording-session duration with the number of captured
16 kHz samples. If the audio buffer is more than 750 ms shorter than the
recording session, Wordhand refuses to transcribe or insert a partial buffer and
shows a recoverable capture failure. Second, a result is flagged when it begins
with a truncated vocabulary prompt term followed by a transcript delimiter,
ends without punctuation while the final two seconds of audio remain active,
or reports a decoded segment ending before sustained later speech. Third, every
recording of at least 30 seconds with sustained speech in its final 20-second
window receives an independent prompt-free tail audit even when Whisper reports
an end-aligned segment and terminal punctuation.

A leading prompt artifact still receives one prompt-free full-buffer decode.
A tail issue first decodes only the final 20 seconds without the vocabulary
prompt. Wordhand keeps the primary text when that tail is already covered and
appends recovered text only after a unique exact normalized overlap of at least
four words. An absent or ambiguous overlap, or unrepresented words before an
apparently covered suffix, falls back to a prompt-free full-buffer recovery.
For the independent long-form audit, that full recovery must be materially
longer and lexically aligned; an equal-length unconditioned result cannot replace
better dictionary spelling. Segment timing remains a useful signal but never
suppresses the independent audit because a retained 65.09-second recording
proved Whisper can report an end-aligned segment while omitting multiple late
sentences. Any failed or non-improving recovery preserves the primary decode.

This avoids deleting legitimate names post hoc, keeps recordings under 30
seconds on the ordinary single-decode path, and bounds long-form recovery work
without trusting a partial merge.
Both passes use the same local WhisperKit model; no audio, vocabulary, or
transcript content leaves the Mac. See
`docs/verification/2026-07-29-transcription-integrity-regressions.md` and
`docs/verification/2026-07-29-tail-recovery-speed.md` and
`docs/verification/2026-07-29-independent-tail-audit.md`.

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
       append every converted chunk to Pending Captures under the same UUID
       preserve complete frames across process death, quit, or interruption
       compare captured samples with monotonic recording duration
       refuse a materially short buffer instead of inserting partial text
       offline rolling benchmark forwards chunks through one ordered stream
  -> local transcriber
       snapshot enabled canonical dictionary spellings
       prioritize recent user corrections; cap prompt at 24 terms
       tokenize them into WhisperKit promptTokens
       guard forced prompt prefill from premature completion
       decode locally with Core ML
       inspect conditioned output for prompt leakage or an active-audio cutoff
       retry suspicious output once without prompt conditioning
       select the retry only when it is demonstrably cleaner or more complete
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
       delete the matching pending-capture journal only after commit
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

## Crash-safe capture recovery

The complete capture exists in two forms while dictation is in flight. RAM
remains the normal authoritative input at release. In parallel, `Pending
Captures` stores an immutable JSON manifest plus ordered append-only frames of
the same 16 kHz Float32 samples. Each frame carries a sequence number, sample
count, and checksum. Recovery accepts only contiguous complete frames, so a
process killed during the final write loses only that unacknowledged torn frame
and cannot fabricate or duplicate audio.

The audio callback only enqueues immutable chunks onto one ordered local writer;
it performs no filesystem work. Release waits for that queue to drain before
sealing the journal. A write error latches the session closed and quarantines
its files instead of allowing a later frame to hide a missing middle. Startup
scans exclude the currently active UUID. Unreadable files remain available for
manual inspection for 30 days, then expire locally.

The journal uses the coordinator's dictation UUID, which later becomes the
History primary key. Normal capture deletes the journal only after History
successfully stores the transcript. Capture, transcription, and History
failures retain it. Explicit user cancellation deletes it. On restart, Wordhand
replays orphaned samples through the same full-buffer transcriber and processor,
saves the result once under the original UUID, and marks it not inserted because
the former focus target is no longer trustworthy. A duplicate History UUID makes
cleanup idempotent after a crash between commit and journal deletion.

The directory is always local and owner-only (`0700`, files `0600`). It is
separate from opt-in Quality Lab retention because recovery is loss prevention,
not evaluation consent. No partial transcript becomes authoritative, and no
recovered text is inserted automatically.

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

1. sanitize model control and non-speech tokens, and normalize a malformed
   decoded `http` or `https` scheme only when it already contains slash
   characters;
2. normalize whitespace;
3. apply custom dictionary replacements;
4. remove unambiguous hesitation sounds such as `um`, `uh`, `erm`, and `hmm`
   deterministically, including stretched forms and surrounding pause
   punctuation; user dictionary substitutions take precedence, and removing
   fillers immediately after sentence punctuation capitalizes the following
   lowercase word;
5. resolve explicit spoken repairs such as `wait, no`, `I meant`, `make that`,
   `correction`, `scratch that`, and immediate false starts; ambiguous language
   is preserved rather than guessed;
6. apply one exact earlier-phrase replacement only from the reserved terminal
   grammar `command correction, replace <old> with <new>`;
7. apply the explicit Casual, Formatted, Professional, or AI Communication
   writing style;
8. validate on-device rewrites for facts, constraints, perspective, modality,
   and uncertainty, retry conservatively once, then use safe local fallback;
9. interpret explicitly supported layout commands;
10. produce the final transcript stored in history.

Earlier-phrase replacement is limited to the current dictation and never reads
the active application's text, selection, cursor, or surrounding document. The
reserved command must be the final standalone clause, survive as the exact
normalized words `command correction replace`, contain one standalone `with`
delimiter, and provide 1–8 lexical tokens on each side. The old phrase must
occur exactly once before the command using Unicode-aware token boundaries.
Matching is case-insensitive so explicit spelling/casing corrections work, but
replacement preserves the newly dictated casing exactly. There is no fuzzy
match, stemming, semantic inference, or partial numeric/domain-token match.

Every rejected command returns the literal cleaned input with a text-free
reason enum. The processor bypasses both deterministic polish and the
Foundation Models formatter on rejection, so no later stage can hide or
rewrite the failed command. After successful insertion, the menu-bar status
temporarily expands to show `correction not applied · text preserved`. That
notice is emitted before History status bookkeeping so a bookkeeping failure
cannot suppress it, and it clears after four seconds or when a new recording
starts. Private operational diagnostics store only the enum reason. Raw
recognition remains unchanged in History, while a successful command appears
only in the processed text.

Layout commands are protected before local style formatting with collision-free
opaque tokens plus the nearest words on both sides as structural anchors. A
formatted result is accepted only when every token survives exactly once, in
order, in its anchored segment, with no invented token. Missing, duplicated,
reordered, moved, or invented tokens force the deterministic protected-source
fallback, so formatter fluency cannot drop or relocate a requested boundary or
expose an internal marker. Restoration changes whitespace and capitalization
only at the exact token boundary: it removes a decoder separator comma, emits
one newline for `command new line` or two for `command new paragraph`, and
capitalizes the first English letter after that break. Formatter-created
whitespace elsewhere is returned unchanged.

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

## Operational diagnostics

Wordhand keeps a separate local operational record so months of ordinary use
can be evaluated from evidence instead of memory. Diagnostics live at
`~/Library/Application Support/Wordhand/Diagnostics` as owner-only `0600`
newline-delimited JSON files inside an owner-only `0700` directory.

The operational schema records identifiers, timestamps, severity, bounded
categorical attributes, and numeric measurements. It has no transcript or audio
payload field, and the store rejects known transcript, prompt, dictionary, and
audio payload keys. Transcript text remains in History; opted-in audio remains
in Quality Lab. Neither is duplicated into diagnostics.

Each dictation receives one correlation ID across:

```text
dictation started
  -> capture duration and signal health
  -> transcription latency and tail-audit outcome
  -> processing latency
  -> history persistence
  -> insertion verification/retry outcome
  -> completion, cancellation, or exact failed stage
```

The capture summary includes RMS, peak, clipped-sample fraction, active-window
fraction, wall time, sample count, and buffered-audio duration without keeping
samples. Transcription records model, latency, word/character counts, prompt
artifact detection, full-retry use, and whether a tail audit verified or
recovered missing text. Insertion records mode, verification strength, retry
count, Secure Input blocking, checkpoint availability, and guarded-undo
availability. App lifecycle records startup, permissions, hotkey readiness,
model warmup, settings changes, normal termination, and an hourly heartbeat
with app uptime, readiness, Low Power Mode, and thermal state.

Files rotate by UTC day, retain at most 90 days, and enforce a strict aggregate
250 MB ceiling by removing the oldest files and then the oldest complete lines
if one day alone exceeds the limit. Malformed lines are counted and skipped so
one interrupted write cannot hide healthy records.

`wordhand diagnostics status`, `report`, `export`, and confirmed `clear`
provide local inspection. Settings exposes Open Folder and Copy Health Report;
report construction runs off the UI thread. The report aggregates successful
and failed stages, latency percentiles, audio health, tail recovery, models,
targets, and event/failure breakdowns. No network analytics, telemetry, upload,
or automatic support submission exists.

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
- `wordhand quality evaluate` scores one or more completely cached local models
  against paired corrected recordings using normalized word and spelling error
  rates, exact-match count, transcription latency, and real-time factor;
- model comparisons run in isolated child processes so each Core ML model is
  released before the next one, with a bounded 30–900 second per-model timeout;
- evaluation never downloads a missing model implicitly, never prints
  transcript or reference text, and can disable dictionary conditioning for a
  controlled recognizer-only comparison;
- `wordhand quality prove-vocabulary` runs transcript-free canonical-term or
  six-order priority-matched pronunciation-alias causal replay in a bounded
  isolated worker, requires independent source and control audio, and never
  persists its verdict or candidate;
- no upload, sync, analytics, or background training path exists.

The files inherit the Mac's volume-at-rest protection when FileVault is enabled;
Wordhand does not claim independent application-level encryption. Corrected
reference text now makes retained audio useful for controlled local evaluation.
The evaluator applies the selected model, optional local dictionary
conditioning, and deterministic transcript cleanup; it deliberately excludes
the generative writing-profile formatter so model comparisons do not measure
paraphrasing. A later fine-tuning workflow must keep all processing local and
receive a separate design and verification pass; Wordhand does not automatically
train on the corpus. See
`docs/verification/2026-07-29-quality-corrections-storage.md` and
`docs/verification/2026-07-29-quality-evaluator.md`.

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

The global writing style remains the understandable default. An optional
application-specific rule may select one of the same four styles for one exact
bundle identifier; display names, app categories, and heuristics never route
formatting. Wordhand captures the target application, resolved style, route
source, and processing mode once when an accepted dictation begins. That
immutable context drives prewarming, processing, History target provenance,
and private lifecycle diagnostics, so an app switch or Settings edit during
speech cannot split one dictation across configurations. Settings changes take
effect on the next dictation. Unknown recovery targets and malformed duplicate
rules fail safe to the global default.

User data stays under:

```text
~/Library/Application Support/Wordhand/
  settings.json
  dictionary.json
  history.sqlite
  Pending Captures/              temporary crash-recovery Float32 journals
  Quality Recordings/             opt-in, automatically expired WAV files
  Models/
```

On the first branded launch, Wordhand copies an existing
`~/Library/Application Support/Parrot` directory into this location through a
staged migration. It never overwrites an existing Wordhand directory and
preserves the legacy directory for rollback.

`com.valyou.wordhand.dev` owns development privacy grants;
`com.valyou.wordhand` owns release grants. Neither channel may replace the
other. Development permission receipts do not prove the signed release identity
works, and the release update gate requires observing that existing grants
survive a real notarized update.

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
