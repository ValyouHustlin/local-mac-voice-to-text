# Three-target installed-app checkpoint — 2026-07-29

## Scope and method

The exact installed `/Applications/Wordhand.app` build from commit `b8470d7`
remained running. No rebuild or permission-identity change occurred.

The same audible local macOS system-voice phrase was played into the real
microphone path for each target:

```text
Wordhand keeps Valyou, WhisperKit, Cloudflare, Tailscale, and Codex local.
```

A controlled Control-Space event started and stopped each recording. This makes
the audio repeatable and exercises the installed app's real global event tap,
audio capture, WhisperKit decoder, formatter, history store, clipboard/paste
inserter, and target application. It does not substitute for a later
physical-key/user-voice compatibility pass.

No browser form was submitted and no audio or transcript was sent to a
transcription service.

## Native target — TextEdit

Target:

```text
TextEdit · Untitled 5
```

Observed output:

```text
Wordhand retains Valyou, WhisperKit, Cloudware, Tailscale, and Codex Mobile.
```

Measured stop-to-visible-text latency: `3,614 ms`.

History receipt:

```text
created:                2026-07-29 07:16:37
audio duration:         10.39 s
transcription duration: 1.96 s
target:                 TextEdit
insertion status:       inserted
```

The first TextEdit attempt contained seven seconds of silence. Wordhand started
and stopped the audio engine but created no transcript or history record, which
is the correct empty-capture behavior.

Verdict: insertion passed; vocabulary accuracy did not. `Cloudflare` became
`Cloudware`, and `local` became `Mobile`.

## Browser target — Google Chrome

The first page was W3Schools' textarea demo. An advertising iframe took focus
between recording and insertion. Wordhand stored `Google Chrome | inserted`,
but direct DOM inspection showed the intended textarea remained empty. This is
a real false-success condition: a successful paste event is not proof that the
intended browser field received text.

The accepted browser target was the ad-free HTML Form Test Page:

```text
https://testpages.eviltester.com/pages/forms/html-form/
textarea[name="comments"]
```

The exact tab was brought to the foreground by URL, the textarea was cleared
and focused, and the same audio was replayed.

Direct DOM observation:

```text
Wordhand keeps Valyou, WhisperKit, Cloudflare, Tailscale, and Codex Mobile.
```

History receipt:

```text
created:                2026-07-29 07:20:25
audio duration:         9.30 s
transcription duration: 1.82 s
target:                 Google Chrome
insertion status:       inserted
```

Verdict: focused textarea insertion passed and all five seeded technical terms
were correct. `local` was still acoustically decoded as `Mobile`.

## Electron target — Visual Studio Code

Target:

```text
Visual Studio Code 1.127.0 · Electron 42.2.0 · Untitled-1
```

The editor was created through **File > New Text File**, not a terminal or
project file. After dictation, direct visual inspection of the focused editor
showed:

```text
Wordhand retains Valyou, Whisperkid, Cloudflare, Tailskill, and Codex Global.
```

History receipt:

```text
created:                2026-07-29 07:21:42
audio duration:         9.59 s
transcription duration: 1.83 s
target:                 Code
insertion status:       inserted
```

Verdict: Electron paste insertion passed. Vocabulary accuracy did not:
`WhisperKit` became `Whisperkid`, `Tailscale` became `Tailskill`, and `local`
became `Global`.

## Checkpoint verdict

The repaired installed build inserted into all three target classes:

1. native AppKit — TextEdit;
2. browser — a focused Chrome textarea;
3. Electron — a VS Code untitled editor.

The checkpoint is not a flawless-accuracy receipt. Across identical system-voice
audio, transcription duration was stable at `1.82–1.96 s`, but vocabulary
accuracy varied. Decode-time conditioning correctly preserved `Valyou` and
`Codex` in all accepted runs and all five seeded terms in the accepted Chrome
run; it did not reliably preserve `Cloudflare`, `WhisperKit`, or `Tailscale`
across all three.

## Product defects promoted by this receipt

1. Add observed high-confidence aliases such as `Cloudware → Cloudflare`,
   `Whisperkid → WhisperKit`, and `Tailskill → Tailscale` through editable
   starter configuration, while avoiding broad replacements that could corrupt
   legitimate prose.
2. Treat target-focus changes during recording/transcription as a recoverable
   insertion conflict. At minimum, warn and retain the transcript instead of
   claiming the originally focused browser field received it.
3. Do not market the starter vocabulary as flawless from the controlled
   benchmark. Repeat the three-target pass with Aaron's physical shortcut and
   natural voice after the alias/focus fixes.
