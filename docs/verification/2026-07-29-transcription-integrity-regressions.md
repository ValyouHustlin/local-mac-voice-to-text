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
Test run with 137 tests in 16 suites passed
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

## Open natural-voice gate

No microphone, global shortcut gesture, or synthetic insertion was driven by
the agent while Aaron was working. Automated checks prove the decision logic,
buildability, installed identity, and permission preflight, not natural speech
behavior.

Before this regression is closed:

1. dictate one short sentence and one 60-second passage with an intentionally
   unpunctuated final clause;
2. confirm neither begins with a vocabulary term that was not spoken;
3. confirm both include the spoken final clause in history and at the cursor;
4. record stop-to-insertion time and whether the conditional retry ran.
