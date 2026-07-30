# Spoken corrections and Maximum Performance receipt — 2026-07-29

Scope: deterministic spoken repairs, local formatter prewarming, ordered rolling
transcription, bounded correction stabilization, and no-data-loss fallback.

## Safety boundary

Aaron was actively working during this checkpoint. No microphone capture,
global event tap, synthetic insertion, application installation, or Wordhand
restart was performed. `/Applications/Wordhand.app` remained the user-owned
running build. The new runtime path therefore has implementation and isolated
verification evidence, not a live-audio latency claim.

## Spoken repair behavior

The release CLI drove the real transcript-processing path without audio or
global input:

```sh
WORDHAND_SAFE=1 /usr/bin/time -p .build/release/wordhand format \
  'Um, send it Friday—wait, no, Monday. Email Blumira—sorry, I meant Valyou. I, I need it reviewed.' \
  --style casual
```

Observed:

```text
Send it Monday. Email Valyou. I need it reviewed.
real 0.26
```

The same input was passed through the on-device Professional formatter:

```text
Send it Monday. Email Valyou. I need it reviewed.
real 1.28
```

Unit fixtures also cover `make that`, `scratch that`, `start over`, multiword
proper names, multiple corrections, empty correction markers, semantic `no`,
and ordinary statements beginning with `I meant`.

## Rolling transcription design

Maximum mode uses one ordered `AsyncStream` from the audio tap to the
WhisperKit actor. It attempts a local decode after each two seconds of new
audio, limits each rolling working window to 20 seconds, and confirms only
segments that agree across successive decodes. The final two segments remain
revisable so an immediate correction is not committed too early.

At release, new preview scheduling stops, any in-flight preview finishes, and
only the uncommitted tail is decoded. The full 16 kHz Float32 capture is still
retained. If any rolling decode fails, Wordhand discards preview output and
batch-decodes that authoritative full buffer.

Four minutes of retained mono Float32 audio is approximately 14.65 MiB; the
existing ten-minute safety limit is approximately 36.62 MiB. Prior live
receipts measured 9.30–10.39 seconds of audio in 1.82–1.96 seconds of
transcription. A naive batch-only projection for 240 seconds is therefore
approximately 45–47 seconds after release. Rolling transcription is designed
to move most of that work under the recording interval, but no new stop-latency
number is claimed until an attended natural-voice run is performed.

Adaptive remains the public default and uses the existing single batch pass.
Maximum is user-selectable and also prewarms the selected on-device Foundation
Models formatting session at startup and recording start. Prepared sessions are
bounded to four instruction/target combinations.

## Automated gates

Commands and observed results:

```sh
/usr/bin/swift test -Xswiftc -warnings-as-errors
# Test run with 107 tests in 14 suites passed.

/usr/bin/swift build -c release -Xswiftc -warnings-as-errors
# Build complete.

/usr/bin/swift test --sanitize=thread
# Test run with 107 tests in 14 suites passed.
```

Focused protocol-backed checks additionally observed:

```text
StreamingTranscriptStabilizerTests: 5 passed
DictationCoordinatorTests: 16 passed
GlobalInputAdapterTests: 11 passed
```

The tests prove ordered chunk forwarding, Adaptive batch routing, Maximum
stream routing, correction-horizon behavior, bounded-window progress,
cancellation cleanup, full-buffer fallback, settings migration, and formatter
prewarming through fakes. They do not prove microphone quality or real
stop-to-insertion latency.

## First installed short receipt

After installing commit `ee1fd48`, Aaron tapped Control-Space in Ghostty,
dictated the requested correction-heavy sentence naturally, tapped
Control-Space again, and observed:

```text
- Send it Monday.
- Email value.
- I need this reviewed.
```

History recorded:

```text
audio:              12.18s
raw:                Send it Friday? Wait, no Monday. Email Blumira? Sorry, I meant value. I need this reviewed.
processed:          - Send it Monday.
                    - Email value.
                    - I need this reviewed.
model:              whisper-large-v3
transcription work: 9.97s
target:             Ghostty
status:             inserted
```

This passed spoken correction, filler/false-start removal, AI Communication
structure, history, and insertion. It exposed a decode-time miss:
`Valyou -> value`.

A broad post-hoc `value -> Valyou` rule was rejected because it would corrupt
ordinary prose. Source inspection showed that the prompt selected
highest-priority terms first but also placed them first in Whisper's simulated
prior-transcript context, farthest from the decode boundary.

The fix preserves selection priority, reverses the selected terms when forming
the prompt, and repeats only the strongest four once at the boundary. On the
same 7.29-second local synthetic fixture:

```text
before: I meant Valio.   2.272s
after:  I meant Valyou.  1.931s
```

The fixture is controlled evidence for the prompt-order change, not a
replacement for Aaron's natural-voice retest.

## Open live receipt

When Aaron is not relying on the current build for active work:

1. install the prompt-priority fix without changing the dictionary or
   transcript store;
2. repeat the short `Valyou` correction sample naturally;
3. dictate for at least four minutes;
4. record audio duration, total inference time, release-to-visible-text time,
   final wording, and any duplicated or missing boundary words;
5. repeat insertion in a native app, browser field, and Electron app.
