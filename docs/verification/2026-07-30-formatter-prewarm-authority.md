# Formatter prewarm authority

Date: 2026-07-30

## Outcome

Operational diagnostics measured local formatting on all 27 observed
dictations, averaging 2.49 seconds. Source inspection showed that Maximum mode
prewarmed profile-and-application instructions, while the real first pass
appended per-dictation meaning-marker and layout-token constraints and therefore
used a different session key.

An oracle now separates stable session instructions, a stable prompt prefix,
dynamic constraints, and private transcript text. It compares the current
dynamic-instruction path with a candidate that uses Apple's public
`LanguageModelSession.prewarm(promptPrefix:)`. The candidate is not the
production default.

## Oracle-first receipt

Before the split, the constrained first-pass check failed:

```text
WORDHAND_SAFE=1 swift test \
  --filter maximumPrewarmMatchesTheConstrainedFirstPassSession
Test run with 1 test in 1 suite failed.
prewarmed instructions != constrained first-pass instructions
```

After the split and production-default pin, seven focused checks passed:

```text
WORDHAND_SAFE=1 swift test --filter \
  'stablePromptCandidateSeparatesDynamicConstraintsFromSessionKey|\
productionFormatterKeepsDynamicInstructionsAuthoritative|\
maximumPerformancePrewarmsTheSelectedStyle|\
writingStylePreservesAndRendersExplicitLayoutCommands|\
droppedLayoutTokenRejectsRewriteAndUsesExactSafeFallback|\
unsafeProfessionalRewriteFallsBackWithoutDroppingConstraints|\
FormatterPrewarmComparisonReceiptTests'
Test run with 7 tests in 2 suites passed after 0.024 seconds.
```

The checks require the stable session key to match its prewarm, require both
layout and meaning constraints exactly once, and retain the existing exact
layout-token validator and safe fallback.

## Real local-model rejection

The private comparison harness read recent raw History inputs locally and
printed only aggregate counts, booleans, and timings. It emitted no transcript,
formatter output, prompt, vocabulary, hash, bundle identifier, or application
name. No microphone, speaker, clipboard, event tap, insertion, network, install,
or restart path ran.

First prompt arrangement, three cases and one iteration:

```text
prepared first-pass hits: 3/3
outputs byte-identical: false
baseline median: 1.596s
candidate median: 1.700s
median improvement: -6.5%
baseline p95: 1.991s
candidate p95: 2.077s
promotion: false
```

The one permitted correction moved the dynamic constraints before the private
text and allowed a one-second prewarm lead:

```text
prepared first-pass hits: 3/3
outputs byte-identical: false
baseline median: 1.606s
candidate median: 1.776s
median improvement: -10.6%
baseline p95: 2.003s
candidate p95: 2.118s
promotion: false
```

Both attempts failed output identity, the required 15% median improvement, and
the no-worse p95 gate. The full 27-case/four-iteration run was correctly skipped
because the bounded probe already disproved promotion. Production remains on
the complete dynamic-instruction path.

## Public formatter receipt

The default local formatter was driven on the three public AI Communication
cases from the prior receipt. Connected prose, a multi-constraint request, and
an ordered sequence each returned byte-for-byte the previously recorded output.

## Source checkpoint

```text
SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 WORDHAND_SAFE=1 swift test
Test run with 368 tests in 38 suites passed after 6.599 seconds.

WORDHAND_SAFE=1 swift build -c release \
  -Xswiftc -warnings-as-errors
Build complete! (20.48s)

WORDHAND_SAFE=1 ./scripts/test-packaging-guards.sh
6/6 guards passed.

/bin/bash -n scripts/*.sh
exit 0

git diff --check
exit 0
```

The full suite first exposed a pre-existing race in the microphone-repair test:
it waited only until the fake incremented its request counter, not until the
controller published the refreshed granted state. The corrected oracle waits
for that observable state and passed 20 consecutive focused runs before the
full suite.

Neutral review initially blocked an unbounded array that recorded every
production formatter run for benchmark accounting. Recording is now off by
default and enabled only for the opt-in comparison test. The follow-up review
returned `SHIP` with no findings at or above 80% confidence.

## Unexercised boundaries

- The rejected candidate was not installed or used for live dictation.
- The comparison proves prepared-session lookup in Wordhand, not the internal
  amount of computation Apple completed during `prewarm`.
- No runtime latency improvement is claimed.
