# Editable pronunciation alias receipt — 2026-07-29

## Claim under test

An editable local dictionary correction should tell Whisper how a spoken or
commonly misrecognized phrase is canonically written before decoding. The same
entry should remain a deterministic post-decode fallback. No name or alias
should be hardcoded into the public application.

## Implementation

`DictionaryVocabularySource` now adds up to eight prioritized associations for
enabled rows whose spoken and replacement values differ. Canonical spellings
remain at the decode boundary. Multiple pronunciations are represented as
ordinary editable rows with the same replacement, so every user's dictionary
can evolve without a schema or source-code change.

WhisperKit does expose local decode-time conditioning through
`DecodingOptions.promptTokens`. This feature uses that API; it did not require a
new decoder workaround. Wordhand's existing narrow prompt-prefill adapter
remains necessary for WhisperKit 1.0's premature end-token behavior.

The UI calls the source field `Pronounced / heard as`. A safe explicit CLI path
also manages the same local store:

```sh
wordhand dictionary add \
  --heard-as "tee mux" \
  --replace-with "tmux"
```

The public repository contains no Aaron-specific aliases. The benchmark aliases
were written only to the local dictionary under
`~/Library/Application Support/Wordhand`.

## Identical silent-audio benchmark

No microphone was opened and no audio was played. The fixture was rendered
directly to an AIFF file:

```sh
/usr/bin/say -v Samantha -r 170 \
  -o /tmp/wordhand-pronunciation-aliases.aiff \
  'Aaron Brown Moore uses tee mux. Aaron Brown Moore reviews tee mux sessions.'
```

Baseline command against the installed build 6 and bundled canonical terms:

```sh
/Applications/Wordhand.app/Contents/MacOS/wordhand models benchmark \
  /tmp/wordhand-pronunciation-aliases.aiff \
  --model whisper-large-v3 \
  --default-vocabulary
```

Observed:

```text
audio: 4.44s
transcription: 4.204s
real-time factor: 0.946x
transcript: Aaron Brownmore uses tmux. Aaron Brownmore reviews tmux sessions.
```

Conditioned command against the new build and the editable local dictionary:

```sh
.build/release/wordhand models benchmark \
  /tmp/wordhand-pronunciation-aliases.aiff \
  --model whisper-large-v3 \
  --user-dictionary
```

Observed:

```text
audio: 4.44s
transcription: 2.119s
real-time factor: 0.477x
transcript: Aaron Browne-Moore uses tmux. Aaron Browne-Moore reviews tmux sessions.
```

The name improved from zero of two exact occurrences to two of two. `tmux`
remained exact in both occurrences. Across both target terms, the result moved
from two of four to four of four exact occurrences. The timing is recorded but
is only one run per build, so it is not evidence of a general twofold speedup.

## Fallback and isolation

The dictionary oracle also passes the same editable rows to
`MutableTranscriptProcessor` and observes:

```text
Aaron Brown Moore uses tee mux.
-> Aaron Browne-Moore uses tmux.
```

The benchmark command rejects selecting bundled, user, and ad hoc vocabulary
sources together. The dictionary remains an owner-only local JSON file. No
microphone capture, event tap, synthetic text insertion, or external network
transmission was used in this receipt.

Strict tests:

```sh
/usr/bin/swift test -Xswiftc -warnings-as-errors
# Test run with 111 tests in 14 suites passed after 0.268 seconds.

/usr/bin/swift test --sanitize=thread
# Test run with 111 tests in 14 suites passed after 0.627 seconds.
```

The release executable also compiled with:

```sh
/usr/bin/swift build -c release -Xswiftc -warnings-as-errors
# Build complete! (8.16s)
```

## Installed build

Build 7 was installed with the stable local signing identity and launch at
login enabled. The installed process was PID 4363. The observed checks were:

```text
Identifier=com.valyou.wordhand
Authority=Wordhand Local Signing
CFBundleVersion=7
microphone: ok
accessibility: ok
input monitoring: ok
Control-Space: ok
```

The installed executable decoded the identical fixture through
`--user-dictionary` in 2.100 seconds and returned:

```text
Aaron Browne-Moore uses tmux. Aaron Browne-Moore reviews tmux sessions.
```

## Residual live gate

The management UI copy is compiled but was not opened over Aaron's active work.
The original P2 gate still remains: create a correction from the most recent
live transcript, repeat it in native, browser, and Electron targets, and observe
the correction end to end.
