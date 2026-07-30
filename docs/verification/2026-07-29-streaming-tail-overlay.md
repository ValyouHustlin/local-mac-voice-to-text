# Streaming tail integrity and minimal processing overlay — 2026-07-29

## Reported failure

An installed Maximum-mode recording stored 48.69 seconds of captured audio, but
the final roughly 20 seconds were absent from both the raw and formatted history
fields. A following 29.59-second recording contained the missing subject matter
in both fields. This isolates the first failure before formatting, inside the
rolling Whisper finalization path.

The first post-relaunch history record was also saved and marked inserted even
though the target did not visibly receive it. This proves the current history
status records a posted paste event, not target acknowledgement.

No transcript contents were copied into this receipt.

## Root cause and correction

Maximum mode previously joined stabilized text from rolling 20-second windows
to a final decode beginning at a segment-derived sample boundary. Whisper
segment timestamps are local to each decode window. Treating them as a lossless
audio cursor can skip speech at a boundary. The same path also emitted raw
Whisper control tokens during the controlled replay below.

The rolling engine remains available to the offline benchmark, but is disabled
in the daily runtime. Its composite is not authoritative, and waiting for
unused rolling work before a complete decode made release slower. Both runtime
modes now decode the complete captured buffer once with silence-aware chunking.
Only that full-buffer result can proceed to formatting, history, and insertion.

Paste delivery now gives the first pasteboard transaction 40 milliseconds to
settle, posts an explicit Command-down, V-down, V-up, Command-up sequence, and
waits 320 milliseconds before restoring the user's clipboard. This is a
hardening change, not a claim that the cold first-paste symptom has been
live-closed.

## Offline rolling-path receipt

No microphone, playback, global event tap, or text injection was used. The
existing 61.72-second Samantha fixture was fed to the rolling path at four times
real-time:

```sh
.build/release/wordhand models benchmark \
  /tmp/wordhand-long-vad-checkpoint.aiff \
  --model whisper-large-v3 \
  --default-vocabulary \
  --streaming
```

Before the correction, the rolling composite included Whisper control tokens
such as `startoftranscript`, language/task markers, timestamps, and
`endoftext`. After the correction, observed output contained none of those
tokens and ended with the complete spoken clause:

```text
Finally, remind Aaron Brown more that Valyou LLC and Valyou Solutions use different names in formal documents.
```

Observed after-correction measurements:

```text
audio: 61.72s
transcription: 21.449s
stop-to-final: 5.717s
real-time factor: 0.347x
```

The total transcription number includes the fixture's accelerated 15-second
feed. `stop-to-final` is the relevant release wait for this controlled run.
This receipt proves full synthetic-fixture tail retention through the same
rolling/finalization code. It does not claim a new natural four-minute
microphone result.

The exact installed build 9 repeated the safe rolling benchmark in 8.916
seconds from stop to final. That measured penalty is why runtime build 10 no
longer launches rolling preview work. The rolling CLI remains a regression
reproducer, not a shipping latency claim.

The source for build 10 then decoded the same complete fixture through the
shipping full-buffer path:

```text
path: full buffer
audio: 61.72s
transcription: 4.763s
real-time factor: 0.077x
```

The final clause remained complete. Removing redundant preview work reduced
the controlled release wait by 4.153 seconds, or 46.6 percent, compared with
the exact installed build 9 rolling replay.

## Overlay receipt

Command:

```sh
.build/debug/wordhand overlay-preview --state processing --seconds 10
```

Observed on the pointer's 6720×3780 display:

- one dark capsule with oval ends;
- one subtle SwiftUI shadow with the native panel shadow absent;
- no `Formatting` or `Inserting` label;
- a 3×3 rounded-square grid with one blue perimeter square;
- the active square advanced clockwise;
- one bare cancel glyph with no divider or outlined button.

The preview command opened no microphone and installed no global input path.
The screenshot was kept in `/tmp` because the surrounding live desktop was not
an appropriate repository artifact.

## Automated gates

```sh
/usr/bin/swift test -Xswiftc -warnings-as-errors
```

Observed:

```text
Test run with 114 tests in 14 suites passed
```

```sh
/usr/bin/swift test --sanitize=thread -Xswiftc -warnings-as-errors
```

Observed:

```text
Test run with 113 tests in 14 suites passed
```

```sh
/usr/bin/swift build -c release -Xswiftc -warnings-as-errors
```

Observed:

```text
Build complete!
```

## Remaining attended receipts

1. Restart the installed app, dictate once into a normal cursor target, and
   confirm that the first paste arrives exactly once.
2. Dictate longer than 45 seconds with a unique spoken tail marker and confirm
   the marker exists in the raw history field and inserted text.
