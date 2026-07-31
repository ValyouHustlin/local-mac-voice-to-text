# Explicit local-model cache repair

Date: 2026-07-30

## Outcome

An interrupted local-model download can no longer look complete enough to enter
an endless generic retry loop. Before WhisperKit loads a cached model, Wordhand
now requires a nonempty JSON configuration and the nonempty metadata, program,
data, and weight files for each required compiled Core ML component.

A structurally incomplete cache produces a specific `Local model needs repair`
state in Welcome and Settings. Wordhand never moves it automatically. One
explicit `Repair Model` action atomically moves only the selected model into an
app-owned quarantine on the same volume, then starts one normal clean model
preparation. A second click cannot start another move or download.

The quarantined bytes remain if the move, replacement download, model load,
pending-capture recovery, or formatter preparation does not complete. They are
removed only after that selected model reaches the same authoritative Ready
point as an ordinary launch. Another model's quarantine, settings, recordings,
transcripts, vocabulary, and history are never touched.

## Oracle-first evidence

The first structural oracle was added before implementation:

```text
WORDHAND_SAFE=1 swift test \
  --filter localWhisperModelRejectsEmptyCompiledComponents \
  -Xswiftc -warnings-as-errors
```

It failed with one issue because the old check accepted empty paths as a
complete model.

The focused final gate passed 10 tests in one suite after 0.135 seconds. It
proves:

- empty or missing compiled components are invalid while a structurally
  complete fixture remains ready;
- the real transcriber classifies an invalid injected cache without invoking
  WhisperKit's download path or mutating a byte;
- explicit repair moves the exact partial bytes once and starts one replacement;
- a destination collision or unsafe model identifier moves nothing;
- successful cleanup removes only the selected model's quarantine;
- transient `Try Again`, repair, and onboarding-completion states remain
  independent and bounded.

The complete macOS adapter suite passed 61 tests in 1.087 seconds.

## Real cached-model evidence

The first candidate validator incorrectly required Core ML `metadata.json` to
be a dictionary. The real compiled models use a top-level array, and the
retained-audio gate rejected the healthy cache with `cachedModelInvalid`. The
validator was narrowed to accept either valid JSON container shape while still
rejecting empty, scalar, or malformed metadata.

After that correction:

```text
WORDHAND_REPLACEMENT_AUDIO_RECEIPT=1 WORDHAND_SAFE=1 \
swift test --filter retainedAudioDecodesAndFormatsDeterministically \
  -Xswiftc -warnings-as-errors
```

The network-disabled real Large v3 corpus passed all 16 authoritative decodes
and all four real formatter outputs after 92.727 seconds. The first cold model
load took 47.30 seconds; the next 15 loads took 1.59–1.75 seconds. This proves
the current healthy 598 MB cache remains accepted; it is not a model-download
or fresh-account claim.

A separate read-only structural inspection accepted all four currently
registered caches: Base English, Large v3, Large v3 Turbo, and Small English.
Each configuration was a JSON object, each compiled metadata file was a JSON
array, and every required compiled file was present and nonempty.

## Visual evidence

The repair state was rendered through the real SwiftUI Welcome view at 560 ×
560 pixels. The render test passed after 0.057 seconds. Inspection at original
resolution showed the `Local model needs repair` title, the 626 MB clean-
replacement explanation, `Repair Model` action, three permission rows, and
disabled `Start Dictating` action legible and unclipped.
The render used no permission prompt, microphone, audio playback, event tap,
clipboard, insertion, network, installed-app replacement, or process restart.

## Source gates

```text
SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 WORDHAND_SAFE=1 swift test
385 tests in 38 suites passed after 5.944 seconds

WORDHAND_SAFE=1 swift build -c release -Xswiftc -warnings-as-errors
Build complete in 19.14 seconds

WORDHAND_SAFE=1 ./scripts/test-packaging-guards.sh
6/6 guards passed

/bin/bash -n scripts/*.sh
passed

git diff --check
clean
```

Independent neutral review returned `SHIP` with no finding at or above 80%
confidence. Its independent focused gate passed the same 10 tests in one suite
after 0.106 seconds, `git diff --check` was clean, and its read-only inspection
independently accepted all four registered cache layouts. The reviewer
confirmed that classification is nonmutating, the explicit move is
model-scoped and revalidated, repeated clicks are phase-gated, cleanup occurs
only after authoritative readiness, and diagnostics contain no user payload.

## Claim boundary

The filesystem oracle exercises a real atomic move in an isolated temporary
cache and exact byte comparison. It does not corrupt or move Aaron's real model
cache. No replacement was downloaded, no fresh macOS account was used, and the
installed build remains unchanged. A genuinely interrupted first download and
successful replacement still require an attended fresh-account receipt before
release.
