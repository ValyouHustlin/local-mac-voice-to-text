# Custom dictionary verification receipt

Date: 2026-07-28

Status: implementation verified; the phase exit receipt remains open because a
new ambient microphone recording was deliberately not made after the baseline
captured unrelated room speech.

## Automated checks

Command:

```text
/usr/bin/swift test
```

Observed after the final review pass:

```text
Testing Library Version: 6.3.1 (937120cbc281cf2)
Test run with 21 tests in 5 suites passed after 0.002 seconds.
```

The dictionary coverage includes deterministic longest-first and
non-cascading replacement, Unicode word boundaries, persistence, directory
creation, deletion, case sensitivity, disabled entries, validation, protection
against unsupported newer schemas, legacy-array migration, and live processor
updates.

Command:

```text
/usr/bin/swift build -c release
```

Observed:

```text
Build complete! (3.22s)
```

## Native UI

Launch command:

```text
.build/debug/parrot run --skip-doctor --no-overlay
```

Observed:

```text
loading whisper-base.en...
✓ whisper-base.en ready
listening on fn hold · model: whisper-base.en · ^C to quit
```

Gesture and target:

1. Clicked the Parrot menu-bar item.
2. Observed `Custom Dictionary…` and a disabled
   `Correct Last Transcript…` before any transcript existed.
3. Clicked `Custom Dictionary…` in the running AppKit app.
4. Observed a native, resizable `Custom Dictionary` window with Heard as and
   Replace with columns plus Add, Edit, and Delete controls.
5. Clicked Add, entered `whisper flow` and `Wispr Flow`, and confirmed.

Observed result:

- the row appeared immediately and the count changed from `0 corrections` to
  `1 correction`;
- `~/Library/Application Support/Parrot/dictionary.json` was created with
  schema version 1 and the entry;
- deleting the selected row through the window returned the count to
  `0 corrections` and persisted an empty entry list;
- the temporary verification entry was therefore not left in Aaron's data.

After adding the phrase-preview safeguard, the rebuilt app was launched again.
Entering the same mapping and clicking Add displayed:

```text
Preview Phrase Replacement
Any occurrence of:
“whisper flow”

becomes:
“Wispr Flow”
```

Choosing Go Back returned to the editor with both entered values preserved.
Choosing Cancel then left the store at `0 corrections`. The app shut down
cleanly with Control-C.

Only the Parrot window was captured for visual inspection; temporary
screenshots were deleted after inspection.

## Still required for the P2 exit gate

- Dictate a phrase Whisper gets wrong.
- Start `Correct Last Transcript…` directly from that completed transcript,
  trim the prefilled phrase, save the correction, and repeat it.
- Observe corrected output in a native app, a browser field, and an Electron
  app.

Until those three live-target observations exist, P2 remains in progress even
though its persistence, processor, and UI implementation are usable.
