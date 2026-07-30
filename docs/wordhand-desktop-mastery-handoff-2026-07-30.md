# Wordhand desktop mastery handoff — 2026-07-30

Read `/Users/legacy/CLAUDE.md` first for Aaron's first-reply contract, then the
repo `AGENTS.md`.

## GOAL

Make Wordhand the strongest possible English-first Mac dictation application:
more accurate, faster, harder to lose work in, and more seamless in daily use,
while the visible product stays as simple as a very good Apple application.

The product may become sophisticated underneath. Complexity earns its place
only when it removes user effort, delay, uncertainty, or failure. Do not expose
internal machinery as extra controls by default.

Desktop macOS and English are the entire product scope for this lane. Do not
build the iPhone companion, multilingual transcription, cloud processing, team
features, or surrounding-document ingestion.

## CURRENT VERIFIED STATE

Verified 2026-07-30 at 09:56 MST:

- Repository: `/Users/legacy/Development/Repos/Products/local-mac-voice-to-text`
- Public remote: `https://github.com/ValyouHustlin/wordhand`
- Branch/head: `master`, `bf2f35c feat: add private operational diagnostics`
- GitHub CI for that head completed successfully:
  `https://github.com/ValyouHustlin/wordhand/actions/runs/30523360749`
- The full local suite passed with 174 tests across 20 suites, and the release
  build passed with warnings treated as errors.
- `/Applications/Wordhand Dev.app` build 22 was observed running as PID 7994,
  signed by the stable `Wordhand Local Signing` identity.
- Installed `wordhand doctor` reported Microphone, Accessibility, Input
  Monitoring, and Control-Space ready.
- The working tree contains only untracked `docs/marketing/`, which predates
  this handoff and is user-owned. Do not stage, edit, delete, or claim it.

The app already has local Whisper Large v3 transcription, decode-time editable
vocabulary conditioning, post-decode correction fallback, four formatting
profiles, filler and spoken-repair cleanup, paste-first insertion with
clipboard restoration and guarded retry/undo, custom dictionary UI, searchable
history, local Quality Lab recordings/evaluation, tail-loss detection and
recovery, configurable hotkeys, settings, stable local signing, and private
90-day operational diagnostics.

Read only the smallest useful durable state first:

1. `docs/architecture.md`
2. `.plan/plan.md`
3. `docs/verification/2026-07-30-operational-diagnostics.md`
4. `docs/verification/2026-07-29-independent-tail-audit.md`
5. `docs/verification/2026-07-29-streaming-tail-overlay.md`
6. `docs/verification/2026-07-29-quality-evaluator.md`

Treat those documents as claims to recheck where cheap, not substitutes for
live output.

## SEQUENCE

Start by turning the remaining desktop opportunities into a ranked product
strategy. The default ranking is:

1. crash-safe rolling capture so a long dictation survives process failure,
   sleep, or accidental quit;
2. safe work-during-speech that reduces stop-to-insertion latency without ever
   allowing a partial result to replace a more complete authoritative decode;
3. local self-learning that uses explicit corrections and retained recordings
   to suggest vocabulary, pronunciation, model, or configuration improvements
   without silently changing behavior;
4. optional application-to-profile routing that removes mode switching while
   keeping one understandable global default;
5. deeper explicit spoken corrections and editing;
6. a native diagnostic/quality view based on real accumulated evidence;
7. polished fresh-Mac onboarding and the signed/notarized update path.

Re-rank only from measured daily-use impact. Build one vertical slice at a time
and leave Aaron with a usable app at every checkpoint. Do not start several
half-connected feature branches.

For the first slice, establish deterministic crash-recovery and latency
oracles before changing the live capture path. Reuse retained local fixtures
and protocol fakes. Preserve the complete captured buffer and authoritative
full-buffer transcription until a candidate incremental pipeline proves equal
or better on beginnings, endings, numbers, negations, technical terms, and
dictionary spellings.

Use headless background subagents for bounded independent work such as an audio
persistence design review, retained-fixture benchmark analysis, test-oracle
design, or neutral diff review. The lead agent owns product judgment,
architecture, source integration, runtime verification, and the final claim.
Do not create sibling tmux windows for sub-work, and do not let multiple agents
edit the same implementation surface concurrently.

Keep context controlled through durable decisions in `docs/architecture.md`,
roadmap state in `.plan/plan.md`, and dated verification receipts. After two
failed corrections on one issue, move that issue into fresh context rather
than stacking patches. Recycle this lead through a new handoff before context
pressure degrades judgment.

## GOTCHAS

The dangerous shortcut is treating a faster partial transcript as useful even
when it quietly loses the beginning or end. This repo already disabled its
rolling daily-runtime composite after natural dictation exposed dropped
boundary speech. Incremental work may precompute, but it does not become
authoritative until identical retained audio and attended natural dictation
prove completeness.

Wordhand installs a global event tap and can inject into Aaron's active Mac.
Never leave a development runtime unattended. Use `WORDHAND_SAFE=1`, protocol
fakes, offline fixtures, and the repo's explicit bounded global-input test
mechanism. Do not run microphone, clipboard, or insertion tests while Aaron is
working.

Audio, transcripts, vocabulary, prompts, history, and corrected references
stay on the Mac. No telemetry or remote AI path is permitted.

## OWNER + AUTONOMY

The `Wordhand Desktop` lane owns desktop-English product strategy and execution
end to end: code, tests, local models, refactors, UI, documentation, commits,
ordinary pushes to Aaron's fork, local signed development builds, and safe
verification.

Proceed autonomously on reversible local work. Surface before spending money,
publishing a release or social post, choosing a Developer ID certificate,
changing the privacy promise, transmitting user content, or performing an
interactive test that could interrupt Aaron's active work. Batch decisions into
one dense request with a recommended default.

## VERIFICATION

Every source checkpoint must at minimum run:

```sh
WORDHAND_SAFE=1 swift test
WORDHAND_SAFE=1 swift build -c release -Xswiftc -warnings-as-errors
WORDHAND_SAFE=1 ./scripts/test-packaging-guards.sh
```

Crash recovery must be exercised by terminating a controlled isolated capture
fixture and recovering the exact beginning and ending after restart. Streaming
or precomputation must replay identical retained English fixtures and report
stop-to-final latency plus exact completeness comparisons against the current
authoritative path.

Before claiming a daily-runtime change, drive one attended natural short
dictation and one long dictation, then verify insertion in a native app, browser
field, and Electron or terminal target as applicable. Record exact gestures,
targets, measured times, and observed output. A green build or unit test is not
a live product receipt.

Run the code-only composed close pipeline before landing product-source
changes, then push and wait for GitHub CI to complete successfully.

## CLAIM DISCIPLINE

Assert only from live output observed in the current session. Do not promote a
fixture result into a natural-voice claim, a posted paste event into proof of
field delivery, or a compiled UI into proof that it looks right. State every
unexercised runtime boundary plainly.

## OUTPUT CONTRACT

Work quietly until a real vertical slice is complete or a genuine Aaron-gated
decision blocks progress. Closeout in at most 30 lines with:

1. outcome and user-visible improvement;
2. exact live and automated verification receipts;
3. latency/accuracy before and after, when applicable;
4. discovered issues added to scope and their disposition;
5. commit, push, CI, installed build, and running-process state;
6. remaining uncertainty and one recommended next action marked `[f]`.

Keep `docs/architecture.md`, `.plan/plan.md`, and dated verification receipts
current. Findings must be in the closeout message, not only in files.

You operate under the Lane Lifecycle Contract:
`/Users/legacy/Development/AI/docs/lane-lifecycle-contract.md`.
