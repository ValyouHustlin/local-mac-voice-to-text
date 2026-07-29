# Wordhand iPhone architecture

## Product boundary

The first target is Aaron's iPhone 17 Pro. The mobile slice belongs in the same
repository because normalization, dictionary behavior, engine comparison, and
benchmark records are product capabilities rather than independent mobile
heuristics.

The privacy invariant is strict: no audio, transcript, dictionary content, or
benchmark data may leave the iPhone. Apple Speech must set
`requiresOnDeviceRecognition`. WhisperKit may download only the explicitly
selected model assets, then inference stays local.

## Why there are two processes

Apple custom keyboards cannot record microphone audio. The iOS project
therefore contains:

- `WordhandMobile`: microphone, private audio corpus, Apple Speech, WhisperKit,
  processing, metrics, permissions, and model selection.
- `WordhandKeyboard`: a low-memory keyboard that opens the containing app when
  iOS permits, previews one ready draft, inserts with `textDocumentProxy`, and
  advances to another keyboard.
- `WordhandMobileCore`: pure, testable App Group handoff and private benchmark
  persistence.
- `WordhandCore`: shared transcript normalization, dictionary matching, model
  registry, the engine protocol, and platform-neutral benchmark schema.

Apple requires the user to enable Full Access before a custom keyboard can read
its containing app's App Group. Wordhand requests that capability only for the
local handoff; the keyboard contains no network client and sends no content
anywhere. It cannot appear in secure fields, and iOS can replace third-party
keyboards in other restricted contexts.

## Storage

The App Group identifier is currently `group.com.valyou.wordhand`. Both targets
must be provisioned with that exact entitlement before installation.

The App Group contains one file:

```text
pending-transcript.json
```

It is atomically replaced with complete file protection. The keyboard consumes
only the UUID it inserted. This avoids an old keyboard process deleting a newer
recording. Drafts older than one hour are purged.

Private app storage contains:

```text
Application Support/Wordhand/Benchmarks/
  Audio/<observation UUID>.caf
  Observations/<observation UUID>.json
```

Each observation records raw and processed text, engine, locale, audio
duration, post-stop transcription duration, and thermal state before and after
inference. Peak resident memory remains an optional field populated by the
physical-device Instruments run. Nothing in this data path uses iCloud or a
network service.

## Engine policy

Both engines implement `AudioFileTranscribing` and consume the same local CAF:

1. Apple Speech with `requiresOnDeviceRecognition = true`.
2. WhisperKit with
   `openai_whisper-large-v3-v20240930_626MB`.

Apple Speech provides a zero-download bootstrap path. Whisper Large is the
accuracy-first candidate Aaron requested. The UI makes the 626 MB download
explicit. Neither is declared the mobile default winner until the same corpus
is measured on the iPhone 17 Pro for transcript quality, post-stop latency,
peak memory, and thermal behavior.

## User flow

1. Enable Wordhand in Settings > General > Keyboard > Keyboards.
2. In a standard field, switch to Wordhand and tap Record.
3. iOS opens the containing app if it permits the extension request.
4. Tap to stop after dictation.
5. Wordhand transcribes and saves the processed draft locally.
6. Return to the originating app using iOS app switching or the system back
   affordance.
7. Switch to Wordhand if necessary and tap Insert.

The source does not assume step 3 or the automatic return behavior works. Both
must be observed on Aaron's device. If iOS refuses the extension open request,
the keyboard tells the user to open Wordhand manually.
