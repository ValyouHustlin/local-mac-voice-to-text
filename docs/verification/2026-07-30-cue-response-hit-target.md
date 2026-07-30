# Cue response and cancel hit target verification — 2026-07-30

## Product change

Start and finish feedback previously sat behind unrelated work:

- start playback was requested only after synchronous `AVAudioEngine` setup;
- finish playback was requested after the fixed 80 ms tail capture and every
  pending crash-recovery journal write had drained.

All three generated tones now use retained `AVAudioPlayer` instances that
decode and call `prepareToPlay()` once during app startup. An accepted start
requests playback before capture-engine startup. Finish playback remains after
the 80 ms tail and input-tap shutdown so the tone cannot enter the transcript,
but it now runs before recovery writes drain.

The recording overlay keeps its existing 10-point X glyph and plain styling.
Its rectangular click target grows from 20 × 20 to 28 × 28 points: 96% more
area without a larger visible control.

## Deterministic oracles

- an injected capture records that accepted-start feedback occurs before
`capture.start()`;
- throwing recovery preparation and capture startup each immediately supersede
  the acknowledgement with rejection feedback and never enter recording state;
- injected audio players prove all three cues are prepared once before the
  first playback request, are not re-prepared on that request, and pause the
  preceding cue when a different cue supersedes it;
- a suspended-stop concurrency oracle proves a normal release consumes one
  explicit finish intent, while X cancellation during the release tail replaces
  it with cancel intent and emits zero stop cues; duplicate stop callbacks are
  silent after the one-shot intent is consumed;
- the overlay geometry contract binds the 10-point glyph and 28-point target;
- all hotkey, coordinator, audio, overlay, and global-input tests remain
  offline and fake-driven.

## Verification receipts

- `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 WORDHAND_SAFE=1 swift test`
  passed 304 tests across 33 suites in 5.562 seconds.
- `WORDHAND_SAFE=1 swift build -c release -Xswiftc -warnings-as-errors`
  completed successfully in 16.32 seconds.
- `WORDHAND_SAFE=1 ./scripts/test-packaging-guards.sh` passed both development
  login-item and unsigned-release identity guards.
- `git diff --check` completed with no output.
- Independent neutral review returned `SHIP` with no finding at or above
  80% confidence after separately passing the seven focused cue/intent tests
  with warnings treated as errors.

The review first exposed a misleading accepted-start cue on recovery or capture
startup failure, then two progressively narrower cancel/finish races. The final
design does not infer sound behavior from transient state: the coordinator owns
an explicit one-shot finish-or-cancel intent, and the stopped-input callback
consumes it exactly once. The suspended-stop oracle binds the release-tail race
that state-only guards missed.

## Claim boundary

The oracles prove call ordering, preparation, and layout geometry. They do not
prove speaker-onset latency, perceived timbre, the rendered hit region, or
natural start/stop feel on Aaron's installed app. Those require one short
attended listening and clicking receipt after a new development build is
installed. No microphone, playback, event tap, clipboard, synthetic keyboard
input, installed-app replacement, or process restart was used in this slice's
isolated verification.
