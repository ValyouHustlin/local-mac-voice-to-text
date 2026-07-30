# Terminal paste regression — 2026-07-29

## User-observed failure

Aaron reported that three consecutive dictations no longer pasted
automatically while working in Ghostty. The two most recent persisted
transcripts before that report were both complete enough to reach insertion and
were recorded as `insertion_failed` with `deliveryNotConfirmed`.

The same session also produced two doubled messages. Inspection found one raw
and one processed transcript per history record, but two Command-V posts in the
insertion adapter whenever Ghostty's Accessibility cursor stayed unchanged.
That establishes an insertion retry defect rather than duplicated
transcription.

## Root cause and repair

Wordhand treated an unchanged Accessibility selection as proof that the first
paste was a no-op. That assumption is valid only for editor surfaces with
reliable cursor reporting. Ghostty can consume the paste without advancing the
selection it reports through Accessibility, so Wordhand sent the transcript a
second time and then incorrectly marked delivery as failed.

The focused application's bundle identifier is now captured with the
Accessibility checkpoint. Known terminal applications disable automatic paste
retry. They receive one Command-V and use the compatibility path when their
cursor remains unchanged. Normal editor targets retain the single verified
retry.

## Automated receipt

Command:

```sh
WORDHAND_SAFE=1 /usr/bin/swift test
```

Observed:

```text
Test terminalPasteDoesNotDuplicateWhenAccessibilityCursorIsUnchanged() passed
Test pasteRetriesOnceAfterAConfirmedNoOpAndCreatesSafeUndo() passed
Test run with 126 tests in 15 suites passed
```

The terminal regression test uses an injected event poster and an unchanged
cursor observation. It observed exactly one paste event. No global event tap,
microphone capture, or synthetic keyboard event was installed by the test.

## Installed-app receipt

Command:

```sh
WORDHAND_BUILD_NUMBER=13 WORDHAND_VERSION=0.1.0 ./scripts/install-app.sh --launch-at-login
WORDHAND_SAFE=1 /Applications/Wordhand.app/Contents/MacOS/wordhand doctor
```

Observed:

```text
Version 0.1.0 (13)
Signature: Wordhand Local Signing
Installed /Applications/Wordhand.app
✓ microphone: ok
✓ accessibility: ok
✓ input monitoring: ok
✓ Control-Space: ok
```

One installed Wordhand process was observed at the application bundle path.
The install preserved the stable local signing identity.

## Honest boundary

Aaron was actively working, so this repair was not exercised with the real
hotkey, microphone, or synthetic paste path by the development lane. The
installed Ghostty behavior remains open until Aaron performs one short
dictation and observes a single automatic paste.
