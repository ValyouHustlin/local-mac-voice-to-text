# Decode-time vocabulary receipt — 2026-07-28

> Historical receipt only. The live commands below predate the current
> global-input safety rule and must not be rerun unattended. See
> `2026-07-28-global-input-safety.md`.

## Claim under test

The same editable local dictionary should condition Whisper before decoding and
remain a post-decode replacement fallback. Vocabulary, formatting instructions,
audio, and transcripts must stay on the Mac.

## WhisperKit API and failure found

The dependency exposes `DecodingOptions.promptTokens` and a public tokenizer.
Wordhand encodes enabled canonical dictionary spellings and passes the ordinary
text tokens into that API.

The original WhisperKit 0.18 and official Argmax OSS/WhisperKit 1.0 decoder both
allowed a sampled end-of-text token to terminate decoding while `promptTokens`
were still being forced. Large v3 returned an empty transcript. Prefix tokens
were rejected as a workaround: a one-term test leaked the prefix into output,
and a five-term test returned only the vocabulary prefix with no speech.

Wordhand's `PromptSafeTextDecoder` delegates model loading, Core ML inference,
language detection, cache handling, and ordinary decoding to WhisperKit. During
prompt prefill only, it prevents the token sampler's completion result and the
first-token confidence threshold from stopping the loop. Normal stopping and
threshold behavior resumes for the first actual output token.

## Controlled five-term benchmark

Fixture command:

```sh
/usr/bin/say -v Samantha -r 170 \
  -o /tmp/wordhand-five-term-vocabulary.aiff \
  'Valyou builds Wordhand with WhisperKit for Blumira and Banana Farmer.'
```

This is a controlled macOS Samantha synthetic voice, not Aaron's microphone.
Audio duration reported by WhisperKit was 3.68 seconds. Both measurements used
the same file, optimized Large v3 model, Argmax OSS/WhisperKit 1.0 decoder, and
Wordhand build. Model warm-up is excluded from the comparison.

Unconditioned command:

```sh
.build/release/wordhand models benchmark \
  /tmp/wordhand-five-term-vocabulary.aiff \
  --model whisper-large-v3
```

Observed:

```text
transcription: 0.782s
real-time factor: 0.212x
transcript: Valaya builds Wordhand with Whisper Kit for Blue Mara and Banana Farmer.
```

Exact requested terms: 2/5 (`Wordhand`, `Banana Farmer`).

Conditioned command using the shipped, versioned default vocabulary path:

```sh
.build/release/wordhand models benchmark \
  /tmp/wordhand-five-term-vocabulary.aiff \
  --model whisper-large-v3 \
  --default-vocabulary
```

Observed:

```text
transcription: 1.673s
real-time factor: 0.454x
transcript: Valyou builds Wordhand with WhisperKit for Blumira and Banana Farmer.
```

Exact requested terms: 5/5. Measured decode cost on this short fixture:
0.891 seconds. No prompt text leaked into the result.

An uncapped 39-term run diluted the same fixture and took 2.087 seconds.
A 24-term prompt produced 5/5, so production prioritizes recent custom
corrections and then fills up to 24 terms from the starter vocabulary.

## Local and upgrade receipts

After launching the real app:

```sh
.build/debug/wordhand run --skip-doctor --dump-wav
```

Observed:

```text
listening on ⌃⌥Z tap · model: whisper-large-v3 · ^C to quit
```

The local dictionary reported seed version 1, 39 editable starter entries, and
owner-only permissions:

```text
mode=-rw-------
installedDefaultVocabularyVersion: 1
entryCount: 39
starterCount: 39
```

The starter list is the packaged
`Sources/WordhandCore/Resources/default-vocabulary.json`, not Swift constants.
The store merges a higher seed version without overwriting custom entries and
does not restore a deleted term at the same seed version.

Source inspection found no network path that carries dictionary terms or
formatting instructions. WhisperKit contacts its public model host for model
metadata/downloads, but recognition and prompt conditioning run locally.
Apple's Foundation Models formatting session is on-device and has deterministic
local fallback.

## Automated checks

```sh
/usr/bin/swift test -Xswiftc -warnings-as-errors
/usr/bin/swift build -c release -Xswiftc -warnings-as-errors
```

Observed:

```text
Test run with 66 tests in 11 suites passed
Build complete! (6.98s)
```

Coverage added for seed migration, non-destructive upgrades, deletion behavior,
editable bundled terms, live vocabulary snapshots, custom-term priority,
24-term capping, forced-prefill completion gating, owner-only file permissions,
and Terminal/iTerm2/Warp/Ghostty/VS Code profile routing.

## Honest remaining gate

The decoder path, actual starter configuration, local persistence, app launch,
and controlled accuracy change were observed. A new term was not added through
the running Dictionary UI and then spoken again into the live microphone in
this receipt. That gesture remains the final custom-dictionary live gate.
