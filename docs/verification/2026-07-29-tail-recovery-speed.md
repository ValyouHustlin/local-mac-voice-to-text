# Tail recovery accuracy and speed — 2026-07-29

## Scope

Reduce the extra wait when Wordhand detects a likely dropped ending without
weakening the existing no-data-loss safeguard.

## Safety boundary

Every measurement replayed an already retained local Quality Lab WAV through
the offline model benchmark. No microphone, audio playback, global event tap,
hotkey, clipboard mutation, or text injection ran.

The test fixture was a 28.79-second natural dictation that had previously ended
at an unfinished phrase even though its retained audio contained later speech.
The public receipt records only the minimal known final oracle and does not copy
the full private transcript.

## Failed first approach

The first implementation treated Whisper's last segment timestamp as proof that
an unpunctuated result covered the audio. The exact replay disproved that
assumption:

```text
transcription: 3.109s
ending: incomplete
```

Whisper reported an end-aligned segment while its text still stopped at the
same unfinished phrase. That implementation was rejected before commit.
Segment timing now adds detection for punctuated early stops but can never
suppress the existing unpunctuated active-tail check.

## Final implementation

For a tail-only integrity issue on audio longer than 15 seconds, Wordhand now:

1. decodes only the final 15 seconds without vocabulary conditioning;
2. preserves the complete primary text before the join;
3. requires one unique exact normalized overlap of at least four words;
4. appends only the recovered suffix;
5. falls back to the previous full-buffer prompt-free recovery if the overlap
   is absent, repeated, unsafe, or the short decode fails.

Leading vocabulary artifacts still use the full-buffer recovery. Tail recovery
also works when the current decode had no vocabulary prompt because changing
the audio window, rather than only the prompt, is what recovers the ending.

## Same-audio alternating benchmark

The installed build 15 executable supplied the previous full-buffer recovery.
The release binary built from this change supplied the 15-second tail recovery.
The two were alternated for five runs against the same copied local fixture:

```sh
WORDHAND_SAFE=1 /Applications/Wordhand\ Dev.app/Contents/MacOS/wordhand \
  models benchmark /tmp/wordhand-tail-integrity.wav \
  --model whisper-large-v3 --user-dictionary

WORDHAND_SAFE=1 .build/release/wordhand \
  models benchmark /tmp/wordhand-tail-integrity.wav \
  --model whisper-large-v3 --user-dictionary
```

Observed transcription seconds:

| Run | Build 15 full recovery | New tail recovery |
| --- | ---: | ---: |
| 1 | 6.010 | 4.542 |
| 2 | 5.823 | 4.628 |
| 3 | 5.681 | 4.636 |
| 4 | 5.407 | 4.535 |
| 5 | 5.406 | 4.462 |
| Median | 5.681 | 4.542 |

All ten runs contained the known final oracle, `Just use what we have.` The new
median was 1.139 seconds faster, a 20.0 percent reduction in transcription time
for this recovery case. This is a same-machine, same-audio measurement for one
known failure shape, not a general latency claim.

## Automated gates

The integrity suite now covers:

- a timestamp that reaches the audio end without suppressing an unpunctuated
  active-tail retry;
- sustained speech after a decoded segment even when the text has punctuation;
- silence and a brief noise spike after a decoded segment;
- a safe four-word overlapping tail merge;
- sentence-boundary preservation;
- rejection of insufficient and ambiguous repeated overlaps;
- the previous leading-prompt, selection, and unrelated-retry cases.

Exact command:

```sh
WORDHAND_SAFE=1 swift test
```

Observed:

```text
Test run with 147 tests in 16 suites passed
```

Exact production build:

```sh
WORDHAND_SAFE=1 swift build -c release -Xswiftc -warnings-as-errors
```

Observed:

```text
Build complete!
```

## Installed development build

Exact installation command:

```sh
WORDHAND_SAFE=1 WORDHAND_BUILD_NUMBER=16 ./scripts/install-app.sh
```

Observed:

```text
Version 0.1.0 (16)
Channel: development
Bundle identifier: com.valyou.wordhand.dev
Signature: Wordhand Local Signing
Installed /Applications/Wordhand Dev.app
```

The installer preserved build 15 as a non-launchable `.app-backup` under
Wordhand's Application Support directory and did not register a login item.
Because `WORDHAND_SAFE=1` deliberately neutralizes runtime setup, the installed
app was then opened normally:

```sh
/usr/bin/open '/Applications/Wordhand Dev.app'
```

The installed process remained alive at its canonical path. Its bundle reported
build 16, `com.valyou.wordhand.dev`, and signing authority
`Wordhand Local Signing`. The installed doctor observed:

```text
microphone: ok
accessibility: ok
input monitoring: ok
Control-Space: ok
```

No live microphone, transcription, hotkey gesture, clipboard mutation, or text
insertion was exercised while Aaron was working. The exact retained failure
audio remains the runtime transcription receipt for this change.
