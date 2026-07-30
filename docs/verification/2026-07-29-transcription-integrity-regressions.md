# Transcription integrity regressions — 2026-07-29

## Scope

This checkpoint addresses two failures observed in Aaron's installed Wordhand
history:

1. a vocabulary-conditioned decode began with a truncated version of a custom
   name followed by a delimiter;
2. a later transcript stopped after an unfinished phrase while its retained WAV
   still contained signal near the end.

The exact private transcript text is intentionally not reproduced here beyond
the minimal regression shapes required by the tests.

## Ground truth

The local history database contained two successive raw Whisper results
beginning with `Aaron Browne-`. This text existed before the transcript
processor ran, so the formatter and insertion code did not create it.

The cutoff record's raw and processed text both ended at
`we'll go into doing`. Its paired local WAV was 28.793063 seconds at 16 kHz
mono. The final 3.793 seconds were not silent: measured mean level was
approximately -40.8 dBFS with a -25.1 dBFS peak. The stored audio therefore
contained evidence after the decoder's unfinished ending.

This evidence supports two separate protections. It does not prove one common
root cause, and it does not prove that the installed behavior is fixed.

## Implementation

- `TranscriptionIntegrityGuard` detects a truncated conditioned term at the
  start and an unpunctuated result over an active two-second audio tail.
- Only a flagged vocabulary-conditioned result receives a second full-buffer
  decode with prompt conditioning disabled.
- The prompt-free result replaces the primary only when it removes the leading
  artifact without materially losing words or produces an equal-or-longer
  complete ending.
- A failed or non-improving retry preserves the primary result.
- `DictationCoordinator` compares monotonic recording duration with captured
  sample duration. A gap above 750 ms produces a visible capture failure before
  transcription or insertion.
- All processing remains inside the running app with the selected local
  WhisperKit model.

## Automated receipt

Exact command:

```sh
WORDHAND_SAFE=1 /usr/bin/swift test
```

Observed result:

```text
Test run with 139 tests in 16 suites passed
```

The nine new guard tests cover:

- the observed `Aaron Browne-` prefix shape;
- a legitimate full name used as the sentence subject;
- an unfinished transcript over an active audio tail;
- an unfinished transcript followed by two seconds of silence;
- choosing a clean prompt-free retry;
- choosing a longer complete retry;
- preserving a complete conditioned term before a colon;
- rejecting an unrelated artifact retry with a similar length;
- rejecting an unrelated longer cutoff retry.

The coordinator test drives a five-second recording session with only one
second of captured samples and observes zero transcription calls, zero
insertions, and the recoverable capture failure.

Exact production-build command:

```sh
WORDHAND_SAFE=1 /usr/bin/swift build -c release -Xswiftc -warnings-as-errors
```

Observed result:

```text
Build complete!
```

## Installed development build

Exact command:

```sh
WORDHAND_SAFE=1 WORDHAND_BUILD_NUMBER=14 ./scripts/install-app.sh
```

Observed result:

```text
Installed /Applications/Wordhand Dev.app
```

The installer did not register a login item. The installed bundle reports
`com.valyou.wordhand.dev`, build `14`, and the stable local signing authority
`Wordhand Local Signing`. After launching it without safe mode, the observed
runtime process was:

```text
/Applications/Wordhand Dev.app/Contents/MacOS/wordhand
```

The installed command-line doctor reported:

```text
microphone: ok
accessibility: ok
input monitoring: ok
Control-Space: ok
```

An offline replay of the exact retained cutoff WAV was attempted after stopping
build 13. WhisperKit logged that it was loading the cached
`whisper-large-v3-turbo` model with the network disabled, but produced no ready
or transcription result after 61 seconds. The benchmark process was terminated.
That attempt is not a passing receipt and supports no accuracy claim.

## Natural-voice receipt

Aaron drove both acceptance dictations with Control-Space into Ghostty using
installed development build 14. The agent did not drive the microphone or
global shortcut.

The short recording was 25.387875 seconds. Its raw result began with the words
Aaron actually spoke rather than a dictionary name and retained the distinctive
ending `this is the end of the transcription`. Local transcription took
2.828782 seconds and insertion status was `inserted`.

The long recording was 61.284938 seconds. Its raw result also had no injected
name prefix and retained the final sentence. Local transcription took 3.910788
seconds and insertion status was `inserted`. The dictionary corrected
`Value LLC` to `Valyou LLC`; `Blumira` was already correct in the raw decode.

This closes the two reported integrity regressions for the observed Ghostty
path. It does not replace the roadmap's separate native/browser/Electron
compatibility gate.

## Follow-up polish from the receipt

The short result exposed one deterministic formatting defect: removing
`Hmm. Um,` after a question mark left the next word lowercase. The long result
also exposed a malformed decoded web scheme, `https:\`, plus an
Aaron-specific `value.solutions` spelling.

Build 15 adds:

- narrow capitalization of the first lowercase word after post-sentence
  fillers are removed;
- normalization of malformed `http:\`, `https:\`, `http:/`, and `https:/`
  schemes to two forward slashes;
- a local editable `value.solutions -> valyou.solutions` dictionary correction
  in Aaron's application-support data, not a hard-coded public rule.

The exact deterministic formatter command:

```sh
WORDHAND_SAFE=1 .build/release/wordhand format \
  'Where is it? Hmm. Um, this is the end of the transcription.' \
  --style casual --application Ghostty
```

produced:

```text
Where is it? This is the end of the transcription.
```

Build 15 was installed at `/Applications/Wordhand Dev.app`; all three privacy
checks and Control-Space remained ready. The retired plain build 13 was
unregistered and moved recoverably to:

```text
~/Library/Application Support/Wordhand/App Backups/
  Wordhand.retired-build-13.20260729-2200.app-backup
```

Only Wordhand Dev remained in `/Applications` and only its runtime process was
observed.
