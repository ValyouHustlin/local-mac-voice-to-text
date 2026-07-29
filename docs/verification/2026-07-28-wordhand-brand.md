# Wordhand identity and public repository receipt

> Historical receipt only. The live commands below predate the current
> global-input safety rule and must not be rerun unattended. See
> `2026-07-28-global-input-safety.md`.

Date: 2026-07-28

Commit: `951fa94` (`brand: rename Parrot to Wordhand`)

## Local package

Commands:

```text
/usr/bin/xcrun swift test
/usr/bin/xcrun swift build -Xswiftc -warnings-as-errors
/usr/bin/xcrun swift build -c release -Xswiftc -warnings-as-errors
.build/debug/wordhand doctor
```

Observed:

- 35 tests in 8 suites passed;
- debug and release builds completed without warnings;
- microphone, Accessibility, and Control-Space checks all reported `ok`;
- the package, library, executable, source directories, and test target use the
  Wordhand identity.

## Data migration

Gesture: stopped the earlier daemon, then launched
`.build/debug/wordhand run --skip-doctor --no-overlay`.

Observed:

- Wordhand reported that it migrated the earlier local data;
- both application-data directories remained present;
- each contained four files, and each history database contained four records;
- a second migration attempt was a no-op in the automated suite.

No transcript contents were read for this check.

## Live app and public screenshot

Command:

```text
.build/debug/wordhand run --skip-doctor --no-overlay \
  --data-directory /tmp/wordhand-public-fixture.NeI2GD
```

Gesture: clicked the `wordhand` Dock item.

Observed:

- the process became frontmost;
- a window titled `Transcript History – Wordhand` opened;
- System Events listed a Dock item named `wordhand`;
- the embedded `W` and text-cursor icon was rendered and visually inspected at
  1024 and 32 pixels;
- the public screenshot at `docs/assets/wordhand-history.png` contains only
  three deliberately non-private fixture records.

Fresh microphone dictation was not repeated during the rename pass. This
receipt verifies the renamed runtime and UI, not a new multi-target dictation
claim.

## Public repository

Observed:

- `https://github.com/ValyouHustlin/wordhand` is public;
- its default branch contains commit `951fa94`;
- the old repository URL resolves to the renamed repository;
- the description and nine product topics are present;
- the rendered README shows the Wordhand icon, product screenshot, current
  feature set, source-build path, roadmap, and provenance notice.

The upstream fork has no software license. The repository is therefore
described as public source, not as carrying an open-source license. No release
was published.
