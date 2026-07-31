# Authenticated release manifest

Date: 2026-07-30

## Outcome

Wordhand's nonpublishing release builder now requires an authenticated
manifest contract in addition to the existing final-byte integrity manifest.
The detached canonical JSON signature uses Ed25519 and binds the exact manifest
bytes, SHA-256 digest, algorithm, and a public-key fingerprint under the domain
`com.valyou.wordhand/release-manifest/v1`.

Production verification accepts only manifest and signature paths. Its trust
anchor is compiled into the signed WordhandCore verifier so a manually
assembled app cannot lose a separate SwiftPM resource bundle; there is no
public-key, algorithm, key-ID, fixture, environment, or sibling-file override.
The build-only CLI is a separate executable and is not packaged in
Wordhand.app. The private-key file must be a nonsymlink regular file owned by
the current user, mode `0600`, containing exactly 32 raw bytes, with no
extended ACL. The CLI opens with `O_NOFOLLOW`, validates with `fstat`, checks
the ACL, and reads through the same descriptor so a path swap cannot change
the validated object.

The production trust anchor compiled into the verifier is intentionally null.
The builder checks that anchor and the matching private key after scalar/source
validation but before building Wordhand.app or making any Apple notarization
request. Release creation therefore remains impossible until Aaron chooses
production key custody and deliberately pins the corresponding public key.

## Oracle-first receipt

The first test run failed because no authentication types existed:

```text
WORDHAND_SAFE=1 swift test --filter ReleaseManifestAuthenticationTests
exit=1
cannot find type 'ReleaseManifestSignatureEnvelope' in scope
```

After implementation:

```text
WORDHAND_SAFE=1 swift test --filter ReleaseManifestAuthenticationTests
Test run with 6 tests in 1 suite passed after 0.004 seconds.
```

The fixture-only suite proves canonical round-trip verification, derived key
fingerprints, exact envelope fields, size bounds, schema and algorithm binding,
manifest/digest/signature tampering, duplicate and noncanonical JSON rejection,
wrong pinned keys, exact trust-anchor fingerprints, and the inability of a
valid fixture key/signature to activate the production API.

## Build-only and packaging probes

```text
WORDHAND_SAFE=1 swift build -c release --product wordhand-release-auth
Build of product 'wordhand-release-auth' complete! (9.58s)

WORDHAND_SAFE=1 ./scripts/test-release-distribution-guards.sh
✓ unsafe public distribution paths are retired
✓ release identity, runtime, entitlement, and notarization policy is fail-closed
```

The distribution guard invokes the production status and fixture-key
preflight and requires exit 78. Static checks reject any CLI
`--public-key`, `--key-id`, `--algorithm`, or fixture surface and require trust
plus private-key preflight before app compilation, then manifest integrity
verification, signing, production verification, and only then the final atomic
move.

Direct live CLI probes observed:

```text
release authentication rejected: productionTrustAnchorUnavailable
release authentication rejected: productionTrustAnchorUnavailable
release authentication rejected: insecurePrivateKeyFile
release authentication rejected: insecurePrivateKeyFile
production_status=78 fixture_preflight=78 extended_acl=78 insecure_mode=78
```

The first line is the compiled-in null anchor, the second proves an owner-only
32-byte fixture key cannot become production trust, and the last two prove
mode `0600` plus an `everyone allow read` ACL and mode `0644` are both rejected
before authentication.

## Source checkpoint

```text
SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 WORDHAND_SAFE=1 swift test
Test run with 339 tests in 35 suites passed after 5.981 seconds.

WORDHAND_SAFE=1 swift build -c release -Xswiftc -warnings-as-errors
Build complete! (9.27s)

WORDHAND_SAFE=1 ./scripts/test-packaging-guards.sh
✓ signed update identity fixtures accept only the exact identity
✓ unsafe public distribution paths are retired
✓ release identity, runtime, entitlement, and notarization policy is fail-closed
✓ development login-item registration is blocked
✓ unsigned release identity is blocked
✓ update identity continuity is fail-closed

/bin/bash -n scripts/*.sh
git diff --check
exit 0
```

The neutral review initially held the diff because a separately packaged
SwiftPM anchor resource could disappear from a manually assembled app and
mode `0600` does not exclude extended ACLs. The durable fixes compile the
anchor into signed code and validate size plus ACLs through the same no-follow
descriptor used to read the key. A fresh Darwin oracle caught the
platform-specific `acl_get_entry` contract (zero means success); getter and
iteration errors now reject the key instead of being interpreted as no ACL.

## Unexercised boundaries

- No production Ed25519 key was generated, selected, accessed, or pinned.
- No Developer ID certificate, Team ID, or notary profile was selected or
  accessed.
- No app or disk image was built, signed, submitted to Apple, installed,
  opened, run, or published.
- Fixture cryptography proves protocol behavior, not production key custody or
  update delivery.
