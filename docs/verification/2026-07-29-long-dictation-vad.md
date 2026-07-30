# Long-dictation silence-aware chunking receipt — 2026-07-29

Scope: improve completeness and speed for recordings longer than one Whisper
model window without changing the short-dictation path.

## Safety boundary

No microphone, global event tap, hotkey, text injection, or live audio playback
was used. `/usr/bin/say -o` rendered a synthetic Samantha voice directly to an
AIFF file. Both benchmark commands decoded that same local file.

## Finding

Wordhand created `DecodingOptions` only when vocabulary prompt tokens existed
and left WhisperKit's `chunkingStrategy` unset. Audio longer than a model window
therefore used sequential fixed-window decoding, even though WhisperKit exposes
a voice-activity chunker that chooses silence boundaries and uses concurrent
workers on macOS.

Wordhand now always creates explicit decode options and selects `.vad`.
Vocabulary prompt tokens remain unchanged when present. WhisperKit checks audio
length before chunking, so recordings shorter than one model window continue
through the existing single-decode path.

## Controlled long fixture

The fixture is 61.72 seconds and contains product names, technical vocabulary,
an explicit spoken correction, numbers, and a final clause after the 60-second
boundary.

Baseline command:

```sh
.build/release/wordhand models benchmark \
  /tmp/wordhand-long-vad-checkpoint.aiff \
  --model whisper-large-v3 \
  --default-vocabulary
```

Observed fixed-window baseline:

```text
audio: 61.72s
transcription: 7.156s
real-time factor: 0.116x
ending: Finally, remind Erin Brown more that Valiyo LLC and Valiyo Solutions use different
```

The baseline stopped before the spoken words `names in formal documents`.

Observed after enabling silence-aware chunking:

```text
audio: 61.72s
transcription: 4.778s
real-time factor: 0.077x
ending: Finally, remind Aaron Brown more that Valyou LLC and Valyou Solutions use different names in formal documents.
```

The new path was 2.378 seconds faster, a 33.2 percent reduction, and retained
the complete final clause. It also improved the two final `Valyou` spellings.
This is a controlled synthetic-voice result, not an attended four-minute
natural-voice claim.

## Short-path regression check

The existing 3.68-second five-term vocabulary fixture remained exact:

```text
audio: 3.68s
transcription: 1.866s
transcript: Valyou builds Wordhand with WhisperKit for Blumira and Banana Farmer.
```

Exact requested terms remained 5 of 5.

## Automated gates

`longTranscriptionUsesSilenceAwareChunkingWithoutVocabulary` proves the
silence-aware strategy remains active even if a user deletes every dictionary
entry.

```sh
/usr/bin/swift test
```

Observed:

```text
Test run with 110 tests in 14 suites passed
```

```sh
/usr/bin/swift build -c release -Xswiftc -warnings-as-errors
```

Observed:

```text
Build complete!
```

## Remaining live receipt

Measure stop-to-insertion latency and completeness on Aaron's natural
four-minute dictation when he explicitly wants an attended microphone run.
