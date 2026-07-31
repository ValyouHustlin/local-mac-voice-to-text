# Honest insertion-delivery evidence

Date: 2026-07-30

## Outcome

History no longer treats posting a keyboard event as proof that the intended
field received the transcript.

- `Inserted` requires verified Accessibility cursor evidence, including a
  verified retry or an acknowledged selection replacement.
- `Sent · unverified` means Wordhand posted the text but the browser, Electron,
  terminal, direct-Unicode, or custom field did not expose reliable delivery
  confirmation. History explains that the transcript remains safe.
- `Copied` records intentional Copy Only behavior.
- `Not inserted` remains reserved for a thrown insertion failure.

This changes evidence and presentation only. It does not add retries, suppress
a compatibility paste, alter clipboard restoration, read surrounding document
content, or change the authoritative transcript.

## Oracle-first evidence

The pure policy oracle was added before implementation:

```text
WORDHAND_SAFE=1 swift test --filter InsertionHistoryStatusPolicyTests \
  -Xswiftc -warnings-as-errors
```

The red run failed to compile because no evidence-to-History policy or honest
status cases existed. The final policy gate passed both tests after 0.001
seconds. It exhaustively binds all eight insertion-verification outcomes:
three acknowledged outcomes become `Inserted`; unavailable, unchanged-terminal,
failed-diagnostic, and absent evidence become `Sent · unverified`; Copy Only
becomes `Copied`.

The final focused cross-layer gate passed 8 tests across 5 suites after 0.891
seconds. It drove:

- a fake event poster plus the real macOS inserter for unavailable direct
  Unicode evidence;
- a verified no-op retry that remains `Inserted`;
- a one-shot terminal paste with unchanged cursor that becomes unverified
  instead of being retried or claimed;
- coordinator save-before-insert and evidence-based final status;
- SQLite restart persistence and raw rollback representation;
- the native History presentation contract.

No microphone, global event tap, clipboard, or real insertion target was used.

## Rollback-compatible persistence

The SQLite schema is unchanged. New successful evidence states retain the
existing `insertion_status = inserted` value and store one versioned marker in
the existing reason column. The current build restores the precise state; an
older rollback build ignores that reason for inserted rows and continues to
load its prior event-posting semantics instead of rejecting a new enum value or
schema.

An isolated real SQLite query observed:

```text
Sent · unverified -> inserted / wordhand:delivery_unverified:v1
Copied             -> inserted / wordhand:copied_only:v1
```

## Visual evidence

The real native History window was rendered at 920 × 620 pixels with one
custom-canvas fixture. The opt-in test passed after 0.198 seconds. Inspection at
original resolution showed:

- an orange `Sent · unverified` detail status;
- the matching sidebar evidence icon;
- `Wordhand sent the text, but this field did not confirm delivery. The
  transcript is safe here.`;
- the complete transcript, target, model, language, audio, and timing metadata;
- existing Reinsert, Copy, Improve Accuracy, and Delete actions without
  clipping.

The rendered surface made no `Inserted` claim.

## Source gates

Observed on 2026-07-30:

```text
SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 WORDHAND_SAFE=1 swift test
390 tests / 39 suites passed after 6.701 seconds

WORDHAND_SAFE=1 swift build -c release -Xswiftc -warnings-as-errors
Build complete after 18.67 seconds

WORDHAND_SAFE=1 ./scripts/test-packaging-guards.sh
All five packaging guards passed

/bin/bash -n scripts/*.sh
exit 0

git diff --check
exit 0
```

An independent read-only review returned `SHIP` with no findings at or above
80% confidence. Its own focused gate passed 8 tests across 5 suites after
0.885 seconds. It confirmed exhaustive status mapping, unchanged thrown-error
handling, build-22-readable rollback encoding, no self-learning consumer of the
private markers, and no new transcript or user-content persistence.

## Claim boundary

The fake-backed adapter proves how real inserter diagnostics map into History,
and the native render proves the presentation. It does not prove delivery in a
particular live field. The installed build remains unchanged, and native,
browser, Electron, terminal, Secure Input, microphone, and clipboard behavior
still require attended verification before a new runtime claim.
