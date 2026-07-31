# Fail-closed update identity preflight

Date: 2026-07-30

## Outcome

`scripts/install-app.sh` now stages and authenticates an app before it stops the
running process, archives the installed bundle, changes LaunchServices state, or
replaces the installed app target.

The preflight requires:

- the channel’s exact plist and signed bundle identifiers;
- valid strict signatures on both candidate and installed bundles;
- the same Team ID and exact designated signing requirement as the installed
  app;
- `/Applications/Wordhand.app` as the only release-update target;
- a build output path separate from the installed target.

A release with no installed identity is rejected and routed to the future
notarized distribution path. Development permits a first local install, but a
subsequent differently signed build fails closed instead of risking privacy
permission churn. The installer still performs no login-item registration or
unregistration.

## Deterministic policy and signed fixtures

```text
/bin/bash -n scripts/install-app.sh \
  scripts/test-packaging-guards.sh \
  scripts/verify-update-identity-policy.sh \
  scripts/verify-app-update.sh \
  scripts/test-update-identity.sh
exit 0

WORDHAND_SAFE=1 ./scripts/test-packaging-guards.sh
✓ signed update identity fixtures accept only the exact identity
✓ development login-item registration is blocked
✓ unsigned release identity is blocked
✓ update identity continuity is fail-closed
```

The matrix accepts an exact development identity. It rejects a wrong plist
identifier, wrong signed identifier, wrong installed identifier, changed Team
ID, changed designated requirement, missing release Team ID, fresh release,
noncanonical release path, either direction of build-output/target overlap,
and invalid candidate or installed signatures. Real ad-hoc signed fixture apps
additionally prove exact-identity and fresh-development acceptance plus
rejection of valid apps with a wrong plist identifier, wrong signed identifier,
or changed requirement. Symlinked installed targets also fail closed.
Sentinels and installed fixtures remain unchanged after every rejection. A
source-order oracle requires preflight before PID discovery and termination.

## Stable local identity probe

A build 23 candidate was created under an isolated `/tmp` directory with the
configured `Wordhand Local Signing` identity and compared read-only against the
installed build 22:

```text
Built /tmp/.../Wordhand Dev.app
Version 0.1.0 (23)
Channel: development
Bundle identifier: com.valyou.wordhand.dev
Signature: Wordhand Local Signing
✓ update identity matches com.valyou.wordhand.dev
Identifier=com.valyou.wordhand.dev
Authority=Wordhand Local Signing
TeamIdentifier=not set
```

The candidate directory was deleted after the probe. No app was installed,
opened, stopped, or replaced.

## Stable-signed rejection probe

The same isolated candidate was copied, changed to
`com.attacker.wordhand`, and validly re-signed with the local identity. The real
preflight observed:

```text
exit=78
update identity rejected: candidate bundle identifier does not match com.valyou.wordhand.dev
```

The installed app remained build 22 and its running PID remained 7994.

## Source checkpoint

```text
SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 WORDHAND_SAFE=1 swift test
Test run with 333 tests in 34 suites passed after 5.908 seconds.

WORDHAND_SAFE=1 swift build -c release -Xswiftc -warnings-as-errors
Build complete! (0.89s)

WORDHAND_SAFE=1 ./scripts/test-packaging-guards.sh
✓ signed update identity fixtures accept only the exact identity
✓ development login-item registration is blocked
✓ unsigned release identity is blocked
✓ update identity continuity is fail-closed

git diff --check
exit 0
```

The final independent diff review returned `SHIP` with no findings after the
canonical path guard rejected equality and both containment directions.

## Unexercised boundaries

- No Developer ID certificate was selected and no release was built.
- No app replacement, login-item action, privacy prompt, or TCC mutation ran.
- Notarization, stapling, Gatekeeper, authenticated download, and first release
  installation remain unimplemented.
- Permission and login-item survival still require two attended notarized
  same-path updates plus a reboot/login observation.
