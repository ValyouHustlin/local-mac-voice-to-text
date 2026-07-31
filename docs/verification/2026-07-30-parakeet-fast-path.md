# Parakeet fast path and confirmed-submit receipt — 2026-07-30

## Outcome

Wordhand now has a selectable FluidAudio/Core ML Parakeet Unified English 0.6B
full-buffer backend. Whisper Large v3 remains the accuracy-first default.
Maximum processing uses immediate deterministic profile formatting instead of
waiting on a generative rewrite. Paste mode has an off-by-default option to
press Return exactly once after confirmed delivery.

No microphone, clipboard, global event tap, synthetic insertion, installed-app
replacement, or relaunch was exercised in this checkpoint.

## Identical-audio backend gate

The checked-in `models backend-compare` command verifies the audio SHA-256,
loads only complete cached models, alternates paired order, and separates the
critical meaning gate from the stricter exact-accuracy gate. Any accuracy
regression exits nonzero by default; a benchmark operator must pass
`--allow-accuracy-regression` to accept the explicit speed tradeoff.

Paired two-run results against `whisper-base.en`:

| Fixture | Audio | Whisper median | Parakeet median | Speedup | Critical | Exact |
| --- | ---: | ---: | ---: | ---: | --- | --- |
| english-completeness-v1 | 12.57 s | 0.334 s | 0.076 s | 4.4× | PASS | REJECT |
| english-boundary-long-v1 | 49.26 s | 1.245 s | 0.278 s | 4.5× | PASS | REJECT |
| english-ambiguous-overlap-v1 | 53.71 s | 1.188 s | 0.307 s | 3.9× | PASS | REJECT |

All runs retained protected beginnings, endings, numbers, and negations.
Parakeet's raw transcript separated or substituted `WhisperKit` and
`Aaron Browne-Moore`; word and character error also regressed against this
Whisper baseline. This evidence supports an explicit speed option, not default
promotion. Parakeet does not claim decode-time vocabulary conditioning;
Wordhand's explicit post-decode dictionary replacements still run.

The downloaded local model occupied 595 MB under Wordhand's application-data
model directory. No audio, transcript, vocabulary, prompt, or history content
was transmitted.

## Automated verification

```text
WORDHAND_SAFE=1 swift test
423 tests in 40 suites passed

WORDHAND_SAFE=1 swift build -c release -Xswiftc -warnings-as-errors
Build complete

WORDHAND_SAFE=1 ./scripts/test-packaging-guards.sh
All five packaging guard groups passed

git diff --check
passed
```

The fake event-poster receipts prove Return follows a verified paste, occurs
once after a verified retry, and is absent for unverified paste, Unicode, and
Copy Only. Return is revalidated against the exact focused Accessibility
element and expected cursor immediately before its key event, after clipboard
restoration, without yielding the main actor. Cache tests prove an incomplete
Parakeet cache is quarantined without byte loss before explicit repair,
concurrent warmups share one model load, and a structurally complete cache that
fails to load becomes explicitly repairable. The app packaging script embeds
FluidAudio's Apache 2.0 license and its bundled third-party licenses.

The release build reports one upstream FluidAudio package warning for its
unhandled `benchmark.md`; Swift warnings as errors still pass.

A source-built development candidate was produced at `dist/Wordhand Dev.app`
as version 0.1.0 build 23, arm64, bundle identifier
`com.valyou.wordhand.dev`, signed by `Wordhand Local Signing`. Codesign strict
verification passed, and the sealed app resources contain FluidAudio's license
plus both bundled third-party license files. The candidate was not installed or
launched.

A neutral first-pass review initially found and blocked the focus-change race
and permissive oracle exit. After the fixes, its re-review verdict was `ship`
with no blocking findings; it independently passed 128 focused tests across the
Parakeet, insertion, and coordinator suites plus `git diff --check`.

## Remaining runtime boundary

The candidate is not installed and the live model picker, natural microphone
accuracy, start/stop cue timing, post-release end-to-end latency, real Return
submission, and native/browser/Electron delivery remain unexercised. An
attended installed-app pass is required before any daily-runtime claim.
FluidAudio 0.15.5 exposes no active inference-cancellation API; coordinator
operation identity prevents a late cancelled result from reaching History or
insertion, but the local Core ML call may continue until it returns.
