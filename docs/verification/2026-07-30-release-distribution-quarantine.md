# Release distribution quarantine and sealed artifact contract

Date: 2026-07-30

## Outcome

The inherited public binary path is now fail-closed:

- `.github/workflows/release.yml` is removed, so a pushed `v*` tag cannot
  publish the unsigned command-line archive;
- `scripts/install.sh` exits 78 before any download, extraction, privilege
  request, or filesystem mutation;
- `scripts/build-release-artifact.sh` can build only a local release artifact
  and has no publish, public-artifact download, install, open, or
  credential-discovery path. SwiftPM may fetch pinned source dependencies when
  its local cache is empty.

The builder requires an explicit numeric version, positive build number, full
clean source commit, Developer ID Application identity, matching ten-character
Team ID, and existing notarytool profile. It builds arm64
`com.valyou.wordhand`, enables hardened runtime and a secure timestamp, signs
only the microphone entitlement, and rejects `get-task-allow`.

The app must pass strict signature, identity, Team, runtime, timestamp, and
entitlement checks before notarization. Apple must report `Accepted`; the
stapled app must pass `stapler validate` and Gatekeeper before packaging. The
signed disk image is separately notarized and stapled, then mounted read-only.
Its complete top-level allowlist is one regular `Wordhand.app` and one exact
`/Applications` convenience link. The nested app is verified again before the
final disk-image bytes and deterministic integrity manifest are moved into one
new release directory. The manifest is re-parsed before that move and must
match the exact schema fields, source identity, asset basename, byte count, and
SHA-256 of those final bytes.

## Oracle-first receipt

Before the policy or builder existed:

```text
WORDHAND_SAFE=1 ./scripts/test-release-distribution-guards.sh
exit=1
exact signed release app: expected success
```

After implementation:

```text
WORDHAND_SAFE=1 ./scripts/test-release-distribution-guards.sh
✓ unsafe public distribution paths are retired
✓ release identity, runtime, entitlement, and notarization policy is fail-closed
```

The matrix accepts exact signed and notarized facts. It rejects wrong plist or
signed identifiers, wrong/missing Team ID, a non-Developer-ID authority,
missing hardened runtime, timestamp, or microphone entitlement,
extra entitlements, `get-task-allow`, missing staple or Gatekeeper acceptance,
malformed version/build/profile inputs, redirected or extra disk-image content,
absent release credentials/commit, tampered final bytes, and an actual ad-hoc
signed app. A parser-level oracle reads real `codesign` output from the fixture
and recognizes its `(adhoc,runtime)` flags while rejecting a non-runtime line.

The ad-hoc probe used a real hardened-runtime app carrying the release
entitlement. The real verifier observed:

```text
release artifact rejected: Team ID does not match the configured release team
exit=78
```

The repository had local tags `v0.0.1` through `v0.0.5`, but this session's
read-only `gh release list --repo ValyouHustlin/wordhand` returned `[]`; no
existing GitHub Release assets were removed.

## Live fail-closed probes

The retired installer was invoked directly:

```text
installer_exit=78
Wordhand does not yet publish an authenticated public installer.
Build the development app from source with ./scripts/install-app.sh.
This retired installer performs no download, extraction, or filesystem mutation.
```

The artifact builder was invoked without release credentials:

```text
builder_exit=78
release packaging rejected: Team ID must contain exactly ten uppercase letters or digits
dist/releases absent
```

A temporary build 24 development app exercised the modified app builder with
the stable local signing identity and explicit arm64 architecture:

```text
Build complete! (2.58s)
Built /tmp/.../Wordhand Dev.app
Version 0.1.0 (24)
Channel: development
Bundle identifier: com.valyou.wordhand.dev
Signature: Wordhand Local Signing
Mach-O 64-bit executable arm64
Identifier=com.valyou.wordhand.dev
Authority=Wordhand Local Signing
TeamIdentifier=not set
```

Strict code-signature verification passed and the temporary directory was
deleted. Nothing was installed or opened.

## Source checkpoint

```text
/bin/bash -n scripts/*.sh
exit 0

/usr/bin/plutil -lint Packaging/Info.plist Packaging/Wordhand.entitlements
Packaging/Info.plist: OK
Packaging/Wordhand.entitlements: OK

SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 WORDHAND_SAFE=1 swift test
Test run with 333 tests in 34 suites passed after 6.157 seconds.
real 9.99

WORDHAND_SAFE=1 swift build -c release -Xswiftc -warnings-as-errors
Build complete! (2.18s)
real 2.84

WORDHAND_SAFE=1 ./scripts/test-packaging-guards.sh
✓ signed update identity fixtures accept only the exact identity
✓ unsafe public distribution paths are retired
✓ release identity, runtime, entitlement, and notarization policy is fail-closed
✓ development login-item registration is blocked
✓ unsigned release identity is blocked
✓ update identity continuity is fail-closed

git diff --check
exit 0
```

The final independent diff review returned `SHIP` with no findings. Its first
pass had correctly held the diff because the real hardened-runtime flag parser
was double-escaped; the shared parser and actual `codesign` fixture oracle are
the durable correction.

## Unexercised boundaries

- No Developer ID certificate or Team was selected or accessed.
- No notary profile was selected or accessed.
- No app or disk image was submitted to Apple, stapled, published, downloaded,
  installed, mounted, opened, or run.
- The emitted manifest is deterministic integrity metadata, not yet an
  independently authenticated update feed.
- Inherited-source provenance remains unresolved per `NOTICE.md`, so publishing
  an installable release remains blocked.
- Gatekeeper/quarantine behavior, first installation, privacy grants,
  login-item registration, and same-path update survival still require
  credentialed and attended receipts.
