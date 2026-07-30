# Quality Lab, paste acknowledgement, and safe undo

Date: 2026-07-29

## Scope and safety

This checkpoint used local files, protocol fakes, the command-line settings
path, and app packaging only. It did not start microphone capture, post a real
paste shortcut, or run a development global event tap while Aaron was working.

## Implemented behavior

- Public and fresh installs keep Quality Lab audio retention disabled.
- Opted-in captures are stored as 16 kHz mono PCM WAV files named by the
  matching transcript-history UUID.
- The recordings directory is `0700`; WAV files are `0600`.
- Retention accepts 1–90 days and prunes at startup and after writes.
- Settings can reveal or delete retained files; CLI commands can report,
  enable, disable, or explicitly clear them.
- Paste observes the focused Accessibility element and selection when
  supported. A confirmed unchanged cursor permits one retry. Changed focus or
  an unexpected cursor is a recoverable error.
- The first process paste gets a 120 ms pasteboard-settle interval; later
  pastes retain the 40 ms path.
- Undo is offered only for a verified insertion. It refuses if the target or
  cursor changed and removes only the recorded inserted range.

## Automated receipt

Command:

```sh
/usr/bin/swift test
```

Observed output:

```text
Build complete! (0.11s)
Test run with 121 tests in 15 suites passed after 1.097 seconds.
```

The two insertion adapter tests used an injected fake event poster and fake
cursor observer. One observed a no-op followed by acknowledgement and exactly
two paste attempts, then verified range-only undo. The other observed two
no-ops, exactly two attempts, an honest error, and no undo token. No synthetic
keyboard event was posted.

A third adapter case acknowledged replacement of an existing selection but
withheld Undo because deleting the new range could not restore the text that
the paste replaced.

The Quality Lab tests wrote a real temporary WAV, observed `RIFF`/`WAVE`
headers, exact transcript-ID filename pairing, `0700`/`0600` permissions, and
selective expiry of an old file while retaining a newer file. A late-write test
also confirmed that deleting one record or clearing the corpus wins over a
queued archive write.

Command:

```sh
/usr/bin/swift test --sanitize thread
```

Observed output:

```text
Build complete! (38.65s)
Test run with 121 tests in 15 suites passed after 1.409 seconds.
```

## Honest open receipts

- No natural microphone capture was run in this checkpoint.
- No real text field was mutated, so Accessibility acknowledgement and undo
  remain implementation-plus-fake claims.
- The installed app still needs an attended first-paste test after relaunch in
  TextEdit, Chrome, and Visual Studio Code.
- Audio files alone are not labeled training data. Actual evaluation or
  fine-tuning needs an explicit corrected-reference transcript workflow.
