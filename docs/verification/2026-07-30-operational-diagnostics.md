# Operational diagnostics receipt — 2026-07-30

## Scope

This checkpoint adds a private, structured record for long-running Wordhand
stress testing. It also persists and surfaces transcription tail-recovery
outcomes in History.

No microphone, clipboard, synthetic keyboard event, or live insertion path was
exercised while Aaron was working. Runtime verification was limited to app
startup, permissions, model warmup, graceful shutdown, storage, report/export,
and read-only database inspection.

## Oracle-first development

The new tests were written against missing APIs before implementation:

- diagnostics-store tests failed because `OperationalDiagnosticsStore` did not
  exist;
- lifecycle tests failed because `DictationCoordinator.onDiagnosticEvent` did
  not exist;
- insertion tests failed because `lastInsertionDiagnostics()` did not exist;
- signal-health tests failed because `AudioSignalMetrics` did not exist.

The completed oracles cover daily rotation, 90-day expiry, a strict aggregate
ceiling including within-day trimming, corrupt-line tolerance, owner-only file
permissions, payload-key rejection, report aggregation, lifecycle correlation,
audio summaries, insertion retry proof, live schema-2-to-3 history migration,
tail outcome persistence, and false recovery-badge prevention.

## Automated receipt

Command:

```sh
WORDHAND_SAFE=1 swift test
```

Observed:

```text
Test run with 174 tests in 20 suites passed
```

Command:

```sh
WORDHAND_SAFE=1 swift build -c release -Xswiftc -warnings-as-errors
```

Observed:

```text
Build complete!
```

Command:

```sh
WORDHAND_SAFE=1 ./scripts/test-packaging-guards.sh
```

Observed:

```text
✓ development login-item registration is blocked
✓ unsigned release identity is blocked
```

The medium first-pass review found and fixed four issues before the final
installation:

1. report construction could read a large archive on the Settings UI thread;
2. the storage ceiling removed whole old files but was not strict when one
   current-day file exceeded the limit;
3. a full retry for an unrelated prompt artifact could falsely display `Tail
   recovered` after the independent tail audit had already proved coverage;
4. installer `SIGTERM` shutdowns bypassed the AppKit termination hook.

## Installed-app receipt

Final install command:

```sh
WORDHAND_SAFE=1 WORDHAND_BUILD_NUMBER=22 ./scripts/install-app.sh
```

Observed:

```text
Version 0.1.0 (22)
Channel: development
Bundle identifier: com.valyou.wordhand.dev
Signature: Wordhand Local Signing
Installed /Applications/Wordhand Dev.app
```

The installer did not register a login item. The bundle passed strict
`codesign` verification. The installed `wordhand doctor` reported:

```text
✓ microphone: ok
✓ accessibility: ok
✓ input monitoring: ok
✓ Control-Space: ok
```

The existing live history database was inspected before and after migration:

```text
before: schema 2, 113 records
after:  schema 3, 113 records
```

No history row was lost. Existing rows receive the neutral `not_audited`
outcome.

The build-21 process was sent one deliberate `SIGTERM`. It exited within the
bounded five-second check, wrote `app.terminated`, and was reopened. Final
build-22 installation then used the same graceful path and wrote a second
termination event. Final observed process:

```text
7994 /Applications/Wordhand Dev.app/Contents/MacOS/wordhand
```

PIDs are transient; the receipt is that one installed build-22 process was
observed after the final reopen.

## Real diagnostic output

After startup, permission checks, model warmup, one graceful shutdown, and
reopen, the installed CLI reported:

```text
retention: 90 days
storage: under 250 MB
files: 1
privacy: metadata only; no transcript text or audio

events: 27
app sessions: 5
warnings: 0
failures: 0
event breakdown:
  app.launched: 5
  app.starting: 5
  hotkey.ready: 5
  model.warmup_completed: 5
  permissions.snapshot: 5
  app.terminated: 2
```

The file was observed at mode `0600` inside a mode-`0700` directory. An export
was created at mode `0600`; its line count matched the source event count at
the time of export. A key scan across the live JSONL and export found none of
the forbidden payload fields:

```text
privacy_payload_scan=clean
```

The event schema contains only timestamps, UUID correlation identifiers,
severity, event name, numeric metrics, and categorical attributes. Raw/final
transcripts stay in History. Optional training recordings stay in Quality Lab.
Neither payload is copied into diagnostics, and the store rejects known text,
prompt, dictionary, vocabulary, sample, and audio payload keys.

## Runtime coverage boundary

The installed app has proven startup, permission, hotkey registration, local
model warmup, report/export, schema migration, and graceful termination events.
Dictation-stage events and the History badge are deterministic-test-backed and
compiled into build 22, but were not created through a fresh natural recording
in this session. The first ordinary dictation after this receipt will begin the
real long-term capture of audio health, latency, tail audits, formatting,
history, and insertion outcomes.
