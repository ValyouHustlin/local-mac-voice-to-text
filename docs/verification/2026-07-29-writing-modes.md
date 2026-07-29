# Four writing modes receipt — 2026-07-29

Scope: explicit Casual, Formatted, Professional, and AI Communication output
styles, local-only model rewriting, migration, semantic safety, and latency.

## Observable behavior

The real production formatter was driven without microphone or global keyboard
input using:

```sh
.build/debug/wordhand format "$SAMPLE" --style <style> --application Slack
```

Sample:

```text
um okay so I think we need to get this launch ready and I want the team to
review the onboarding because people keep getting confused and then we should
probably tighten the copy but do not change the pricing section and I also want
a short summary for Aaron by Friday and maybe include the three biggest risks
```

Observed:

```text
Casual (0.27s)
Okay so I think we need to get this launch ready and I want the team to review
the onboarding because people keep getting confused. Then we should probably
tighten the copy but do not change the pricing section and I also want a short
summary for Aaron by Friday and maybe include the three biggest risks.

Formatted (1.45s)
Okay, so I think we need to get this launch ready. I want the team to review the
onboarding because people keep getting confused. Then we should probably
tighten the copy, but do not change the pricing section. I also want a short
summary for Aaron by Friday and maybe include the three biggest risks.

Professional (1.91s)
I think we need to get this launch ready. I want the team to review the
onboarding because people keep getting confused. Then we should probably
tighten the copy, but do not change the pricing section. I also want a short
summary for Aaron by Friday, and maybe include the three biggest risks.

AI Communication (1.82s)
- Okay, so I think we need to get this launch ready.
- I want the team to review the onboarding because people keep getting confused.
- Then we should probably tighten the copy, but do not change the pricing section.
- I also want a short summary for Aaron by Friday and maybe include the three biggest risks.
```

These are warm local measurements on Aaron's M5 Max. They are not cold-start
or cross-device claims.

After installation, the packaged production formatter was also driven directly:

```sh
~/Applications/Wordhand.app/Contents/MacOS/wordhand format \
  "um I think we should ship this and then do not remove API v2 and then ask Aaron to review it" \
  --style aiCommunication --application Terminal
```

Observed:

```text
- I think we should ship this.
- Then do not remove API v2.
- Then ask Aaron to review it.
```

The first production-model comparison exposed an unsafe rewrite: Professional
changed “I need to send Aaron an update” into text addressed to Aaron. The
rewriter contract and validator were then strengthened to preserve speaker
perspective, actor and recipient roles, modality, uncertainty, names, numbers,
technical terms, and negations. The same sentence was rerun; the unsafe form was
no longer emitted.

AI Communication applies deterministic bullets when an otherwise acceptable
local rewrite contains three or more separate sentences but remains a flat
paragraph. No surrounding application text is read.

## Automated gate

Command:

```sh
/usr/bin/swift test -Xswiftc -warnings-as-errors
```

Observed:

```text
Test run with 79 tests in 12 suites passed
```

Coverage includes the four explicit choices, legacy setting migration, distinct
local rewrite instructions, conservative retry and fallback, speaker and
modality preservation, unsafe rewrite rejection, and deterministic agent
structure.

## Privacy and residual risk

All rewrite calls use Apple's on-device Foundation Models framework. There is
no network fallback and no surrounding-document read. Casual never invokes the
language model.

The final app still requires Aaron's one-time Microphone and Accessibility
approvals before live dictation through the installed bundle can be exercised.
This receipt verifies the exact production formatting path independently of
those permissions; it does not claim a new microphone-to-insertion run.
