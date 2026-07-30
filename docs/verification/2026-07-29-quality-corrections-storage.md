# Corrected references, storage ceiling, and build 12

Date: 2026-07-29 MST

## Scope

This checkpoint added:

- corrected reference text on transcript-history records;
- `Improve Last Transcript Accuracy…` from the menu bar and the selected
  History record;
- version-one to version-two history migration;
- a selectable 250 MB–10 GB aggregate Quality Lab recording ceiling, with a
  2 GB default and oldest-first deletion;
- aggregate storage reporting in `wordhand quality status`;
- cached vocabulary prompt tokens and cancellation of stale rolling partial
  work at finalization;
- installer cleanup so rollback and build bundles do not compete with the
  installed app in LaunchServices or Spotlight.

All audio, references, dictionary inputs, and settings remain local. Public and
fresh-install Quality Lab retention remains disabled by default. This
checkpoint adds no training job, upload, sync, analytics, or network transcript
path.

## Oracle-first checks

Before implementation, the focused tests were added and run. Compilation failed
because the production APIs did not yet exist:

- `TranscriptHistoryStore.updateReferenceText`;
- `TranscriptRecord.referenceText`;
- `TranscriptHistoryStore.labeledRecordCount`;
- `LocalQualityAudioArchive.enforceMaximumBytes`;
- `AppSettings.qualityAudioMaximumBytes`.

The test expectations were then left intact while the production paths were
implemented. The focused post-implementation command was:

```sh
swift test --filter \
  'qualityLabStorageLimitSavesImmediately|storesCorrectedReferenceTextForQualityEvaluation|migratesVersionOneHistoryWithoutLosingRecords|storageLimitRemovesOldestRecordingsFirst'
```

Observed:

```text
Test run with 4 tests in 3 suites passed after 0.029 seconds.
```

The storage fixture wrote three 46-byte WAV files with distinct creation times,
applied a 92-byte ceiling, and observed the oldest file removed while the two
newer files and exact 92-byte total remained. The migration fixture created a
real version-one SQLite schema and record, opened it through the current store,
and observed the record intact with a writable `reference_text` column.

## Full automated gates

Command:

```sh
swift test
```

Observed final line:

```text
Test run with 125 tests in 15 suites passed after 1.049 seconds.
```

Thread Sanitizer command:

```sh
swift test --sanitize=thread
```

Observed final line:

```text
Test run with 125 tests in 15 suites passed after 1.538 seconds.
```

Release gate:

```sh
swift build -c release -Xswiftc -warnings-as-errors
```

Observed:

```text
Build complete! (8.62s)
```

Both installer scripts also passed `/bin/bash -n`.

## Offline transcription measurement

No microphone, playback, global event tap, or text insertion was used. The same
11.00-second local JFK fixture, Large v3 Turbo model, starter vocabulary, and
rolling benchmark command were used before and after:

```sh
.build/debug/wordhand models benchmark \
  .build/checkouts/argmax-oss-swift/Tests/WhisperKitTests/Resources/jfk.wav \
  --model whisper-large-v3-turbo \
  --streaming \
  --default-vocabulary
```

Before:

```text
transcription: 4.854s
stop-to-final: 2.167s
transcript: And so, my fellow Americans, ask not what your country can do for you, ask what you can do for your country.
```

After:

```text
transcription: 4.259s
stop-to-final: 1.556s
transcript: And so, my fellow Americans, ask not what your country can do for you, ask what you can do for your country.
```

This is one controlled before/after, approximately 28% lower stop-to-final
time, with identical output. It is evidence for the isolated rolling path, not
a natural-voice or daily-runtime latency claim. Daily runtime still uses the
authoritative full-buffer decode.

## Installed-app receipt

Install command:

```sh
WORDHAND_BUILD_NUMBER=12 WORDHAND_VERSION=0.1.0 \
  ./scripts/install-app.sh --launch-at-login
```

Observed:

```text
Version 0.1.0 (12)
Signature: Wordhand Local Signing
Wordhand will launch when you sign in
Installed /Applications/Wordhand.app
```

The final installed checks observed:

```text
CFBundleVersion: 12
codesign --verify --deep --strict: success
Authority=Wordhand Local Signing
processes at /Applications/Wordhand.app: 1
history PRAGMA user_version: 2
history column: reference_text
microphone: ok
accessibility: ok
input monitoring: ok
Control-Space: ok
Quality Lab: enabled, 7-day retention
recordings: 0
storage: Zero KB / 2 GB
```

The installer preserved 23 existing rollback bundles as `.app-backup`,
observed no remaining `.app` directory in the rollback folder, and observed
LaunchServices list only `/Applications/Wordhand.app` after build output was
unregistered. The build directory contains `.metadata_never_index`.

## Honest residuals

- Aaron was working, so no microphone capture, synthetic input, or live
  dictation was performed.
- The corrected-reference dialog and new Settings picker compiled and their
  persistence paths were exercised through AppKit/core tests, but the real
  installed windows were not opened or clicked because that would steal focus.
- No natural recording exists yet to prove a retained WAV and manually corrected
  reference as an end-to-end pair.
- Build 12 is signed with Aaron's persistent local identity and is production
  ready for his Mac. A public redistributable release still requires upstream
  license resolution, Developer ID signing, hardened runtime, and notarization.
