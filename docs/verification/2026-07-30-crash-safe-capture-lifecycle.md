# Crash-safe capture lifecycle verification — 2026-07-30

## Outcome

The process-death oracle now sends audio through the same ordered background
writer used by live `AudioCapture`. Each immutable chunk receives a sequence,
and only the contiguous sequence actually appended to the journal is
acknowledged. A hard process death recovers that exact prefix without gaps,
duplicates, reordering, or fabricated samples.

Standard Quit now defers application termination until an active capture has
stopped, drained its queued frames, synchronized the journal, and left the
journal available for restart recovery. A system-sleep notification invokes the
same preservation operation; when local execution and the model are available,
the ordinary full-buffer recovery path saves the transcript to History without
insertion.

Normal release, Quit, and sleep share one capture-stop task. An interruption
during the 80 ms release tail waits for the existing stop instead of issuing a
second hardware stop. The complete in-memory buffer and authoritative
full-buffer transcription path are unchanged.

## Oracle-first failures

The new queued-writer and lifecycle tests were added before implementation and
initially failed to compile because the acknowledgement writer, preservation
operation, deferred termination gate, and sleep controller did not exist.

The first lifecycle implementation then exposed a Swift runtime abort:

```text
freed pointer was not the last allocation
```

Fresh-context diagnosis under LLDB traced it to the existing recording-limit
timer: cancellation dropped the final `Task` handle while its injected sleep was
still suspended. Timer cancellation now retains and awaits the task before
capture stop. A deterministic suspended-sleep oracle proves cancellation cannot
advance to hardware stop until that timer task exits.

## Deterministic evidence

`CrashSafeCaptureJournalTests` now proves:

- acknowledgement advances only after each ordered append completes;
- a blocked later frame cannot make the earlier acknowledged prefix ambiguous;
- an append failure latches, never acknowledges a later frame, and quarantines
  the session;
- four minutes of equivalent 16 kHz samples retain exact count, beginning, and
  ending.

Coordinator and macOS adapter oracles prove:

- Quit/sleep preservation waits for capture stop and performs no transcription
  or insertion inside the interruption boundary;
- interruption during the release tail waits for the existing stop;
- the prepared recovery UUID is neither committed nor discarded;
- termination completion is withheld until preservation completes;
- duplicate sleep notifications coalesce into one preserve/recover operation;
- the configured workspace sleep notification reaches that operation;
- recording-limit cancellation is joined before capture stop.

The microphone-free process fixture was terminated with `SIGKILL`, reopened in
a fresh process, and recovered exact beginning and ending bit patterns:

```text
process crash recovery: exact
samples=7 first=2147483648 last=1065353215 checksum=11754212509259895836
```

The focused warnings-as-errors run passed 81 tests across the journal,
coordinator, and macOS adapter suites. The same 81 tests passed under Thread
Sanitizer in 15.351 seconds with no reported race.

The final serialized safe suite passed 314 tests across 33 suites in 5.652
seconds. The release build completed in 16.56 seconds with warnings treated as
errors. Both packaging safety guards passed, and `git diff --check` completed
with no output.

## Claim boundary

This proves exact recovery of frames acknowledged by the real queued writer and
deterministic Quit/sleep lifecycle ordering. It does not prove recovery of audio
still inside the microphone device or waiting unacknowledged in process memory,
power-loss durability, actual macOS sleep/wake behavior, an installed-app Quit,
or a natural recovered transcript. Those remain attended runtime boundaries.
No microphone, playback, global event tap, clipboard mutation, insertion,
installed-app replacement, installed-runtime restart, or real sleep action was
used.
