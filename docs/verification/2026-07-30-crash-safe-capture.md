# Crash-safe rolling capture — 2026-07-30

## Outcome

Wordhand now writes every converted 16 kHz Float32 microphone chunk to a private
append-only journal while retaining the unchanged complete in-memory buffer as
the normal authoritative transcription input. If the process dies, quits, or
is interrupted before History commits, the next launch recovers complete
acknowledged frames, runs the same full-buffer transcription path, and saves the
result to History without inserting into an untrusted focus target.

The journal and History row share one UUID. Wordhand deletes the journal only
after History commits. A restart after a commit-before-delete crash sees the
duplicate UUID and removes the stale journal without creating a second row.
Explicit cancellation deletes the journal because discarding was the user's
intent.

## Storage and privacy

Recovery data lives under `Pending Captures` in Wordhand's local Application
Support directory. The directory is mode `0700`; manifests and audio journals
are mode `0600`. Audio uses framed little-endian Float32 samples rather than
Quality Lab's PCM16 WAV so the recovery oracle can compare exact bit patterns.
Every frame carries a sequence number, sample count, and checksum. A torn or
corrupt final frame is ignored while earlier contiguous frames remain usable.
Filesystem writes run on one ordered background queue rather than the real-time
audio callback, and normal stop waits for the queue to drain. Any append failure
quarantines the whole journal so a later frame cannot disguise a missing middle.
Malformed, empty, or torn-first-frame sessions are isolated without blocking
healthy recovery and expire after 30 days.

No audio, transcript, identifier, or metric leaves the Mac. Recovery storage is
separate from optional Quality Lab retention because preventing active-work loss
is not model-evaluation consent.

## Deterministic process-death oracle

The microphone-free helper wrote two frames containing seven adversarial Float32
samples, acknowledged the final frame, then was terminated with `SIGKILL`. A
fresh process reopened the same isolated temporary directory:

```sh
WORDHAND_SAFE=1 ./scripts/test-crash-recovery.sh
```

Observed:

```text
process crash recovery: exact
samples=7 first=2147483648 last=1065353215 checksum=11754212509259895836
```

This proves exact recovery of every sample handed to the journal before process
termination, including the beginning and ending. It does not claim recovery of
audio still buffered inside the microphone device or `AVAudioEngine`.

## Automated coverage

Focused journal tests cover exact Float bit patterns after reopen, torn-final
frame rejection, append-failure latching, active-capture scan exclusion,
per-capture quarantine and expiry, owner-only permissions, retain-until-commit
cleanup, and a four-minute-equivalent capture with exact sample count and
boundary markers. Coordinator tests cover recovery to History without insertion,
cleanup only after the History save, and cancellation without resurrection.

Final full suite:

```sh
WORDHAND_SAFE=1 swift test
```

Observed:

```text
Test run with 186 tests in 21 suites passed after 1.575 seconds.
```

Warnings-as-errors release build:

```sh
WORDHAND_SAFE=1 swift build -c release -Xswiftc -warnings-as-errors
```

Observed:

```text
Build complete! (10.84s)
```

Packaging guards:

```sh
WORDHAND_SAFE=1 ./scripts/test-packaging-guards.sh
```

Observed:

```text
development login-item registration is blocked
unsigned release identity is blocked
```

A medium-effort neutral review first found four blocking lifecycle and callback
issues. After correction, a second pass found three error/concurrency/retention
issues. The final fresh pass returned `ship` with no blocking or non-blocking
finding above its 80/100 reporting threshold.

## Runtime boundary

No microphone, global event tap, clipboard mutation, text injection, or installed
app replacement was exercised. Build 22 remained running from the prior
checkpoint. The source change is deterministic-test-backed but is not yet an
attended natural-dictation or installed-build claim.
