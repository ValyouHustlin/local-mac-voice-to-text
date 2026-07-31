#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" && /bin/pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && /bin/pwd)"
WORK_DIRECTORY="$(/usr/bin/mktemp -d /tmp/wordhand-release-guards.XXXXXX)"
trap '/bin/rm -rf "${WORK_DIRECTORY}"' EXIT

expect_exit_78() {
    local description="$1"
    shift

    set +e
    "$@" >/dev/null 2>&1
    local status=$?
    set -e

    if [ "${status}" -ne 78 ]; then
        /bin/echo "${description}: expected exit 78, observed ${status}" >&2
        exit 1
    fi
}

expect_success() {
    local description="$1"
    shift

    if ! "$@" >/dev/null 2>&1; then
        /bin/echo "${description}: expected success" >&2
        exit 1
    fi
}

POLICY="${SCRIPT_DIR}/verify-release-artifact-policy.sh"
PACKAGE_INPUT_POLICY="${SCRIPT_DIR}/verify-release-package-input-policy.sh"

expect_success \
    "exact signed release app" \
    "${POLICY}" \
    signed \
    TEAM123456 \
    com.valyou.wordhand \
    com.valyou.wordhand \
    TEAM123456 \
    "Developer ID Application: Wordhand Test (TEAM123456)" \
    arm64 \
    1 \
    1 \
    1 \
    1 \
    0 \
    0 \
    0

expect_success \
    "exact notarized release app" \
    "${POLICY}" \
    notarized \
    TEAM123456 \
    com.valyou.wordhand \
    com.valyou.wordhand \
    TEAM123456 \
    "Developer ID Application: Wordhand Test (TEAM123456)" \
    arm64 \
    1 \
    1 \
    1 \
    1 \
    0 \
    1 \
    1

expect_exit_78 \
    "wrong release plist identifier" \
    "${POLICY}" \
    signed TEAM123456 com.attacker.wordhand com.valyou.wordhand \
    TEAM123456 "Developer ID Application: Wordhand Test (TEAM123456)" \
    arm64 1 1 1 1 0 0 0

expect_exit_78 \
    "wrong release signed identifier" \
    "${POLICY}" \
    signed TEAM123456 com.valyou.wordhand com.attacker.wordhand \
    TEAM123456 "Developer ID Application: Wordhand Test (TEAM123456)" \
    arm64 1 1 1 1 0 0 0

expect_exit_78 \
    "wrong release Team ID" \
    "${POLICY}" \
    signed TEAM123456 com.valyou.wordhand com.valyou.wordhand \
    TEAM654321 "Developer ID Application: Wordhand Test (TEAM654321)" \
    arm64 1 1 1 1 0 0 0

expect_exit_78 \
    "non-Developer-ID authority" \
    "${POLICY}" \
    signed TEAM123456 com.valyou.wordhand com.valyou.wordhand \
    TEAM123456 "Apple Development: Wordhand Test (TEAM123456)" \
    arm64 1 1 1 1 0 0 0

expect_exit_78 \
    "non-arm64-only release executable" \
    "${POLICY}" \
    signed TEAM123456 com.valyou.wordhand com.valyou.wordhand \
    TEAM123456 "Developer ID Application: Wordhand Test (TEAM123456)" \
    "x86_64 arm64" 1 1 1 1 0 0 0

expect_exit_78 \
    "missing hardened runtime" \
    "${POLICY}" \
    signed TEAM123456 com.valyou.wordhand com.valyou.wordhand \
    TEAM123456 "Developer ID Application: Wordhand Test (TEAM123456)" \
    arm64 0 1 1 1 0 0 0

expect_exit_78 \
    "missing secure timestamp" \
    "${POLICY}" \
    signed TEAM123456 com.valyou.wordhand com.valyou.wordhand \
    TEAM123456 "Developer ID Application: Wordhand Test (TEAM123456)" \
    arm64 1 0 1 1 0 0 0

expect_exit_78 \
    "missing microphone entitlement" \
    "${POLICY}" \
    signed TEAM123456 com.valyou.wordhand com.valyou.wordhand \
    TEAM123456 "Developer ID Application: Wordhand Test (TEAM123456)" \
    arm64 1 1 0 1 0 0 0

expect_exit_78 \
    "extra signed entitlement" \
    "${POLICY}" \
    signed TEAM123456 com.valyou.wordhand com.valyou.wordhand \
    TEAM123456 "Developer ID Application: Wordhand Test (TEAM123456)" \
    arm64 1 1 1 2 0 0 0

expect_exit_78 \
    "debug entitlement enabled" \
    "${POLICY}" \
    signed TEAM123456 com.valyou.wordhand com.valyou.wordhand \
    TEAM123456 "Developer ID Application: Wordhand Test (TEAM123456)" \
    arm64 1 1 1 1 1 0 0

expect_exit_78 \
    "notarized phase without stapled ticket" \
    "${POLICY}" \
    notarized TEAM123456 com.valyou.wordhand com.valyou.wordhand \
    TEAM123456 "Developer ID Application: Wordhand Test (TEAM123456)" \
    arm64 1 1 1 1 0 0 1

expect_exit_78 \
    "notarized phase without Gatekeeper acceptance" \
    "${POLICY}" \
    notarized TEAM123456 com.valyou.wordhand com.valyou.wordhand \
    TEAM123456 "Developer ID Application: Wordhand Test (TEAM123456)" \
    arm64 1 1 1 1 0 1 0

expect_success \
    "valid release package inputs" \
    "${PACKAGE_INPUT_POLICY}" \
    1.2.3 \
    42 \
    TEAM123456 \
    "Developer ID Application: Wordhand Test (TEAM123456)" \
    wordhand-notary

expect_exit_78 \
    "invalid release version" \
    "${PACKAGE_INPUT_POLICY}" \
    "../../1.2.3" \
    42 \
    TEAM123456 \
    "Developer ID Application: Wordhand Test (TEAM123456)" \
    wordhand-notary

expect_exit_78 \
    "invalid release build number" \
    "${PACKAGE_INPUT_POLICY}" \
    1.2.3 \
    latest \
    TEAM123456 \
    "Developer ID Application: Wordhand Test (TEAM123456)" \
    wordhand-notary

expect_exit_78 \
    "release identity does not name configured team" \
    "${PACKAGE_INPUT_POLICY}" \
    1.2.3 \
    42 \
    TEAM123456 \
    "Developer ID Application: Wordhand Test (TEAM654321)" \
    wordhand-notary

expect_exit_78 \
    "invalid notary profile name" \
    "${PACKAGE_INPUT_POLICY}" \
    1.2.3 \
    42 \
    TEAM123456 \
    "Developer ID Application: Wordhand Test (TEAM123456)" \
    "--key attacker"

expect_exit_78 \
    "legacy remote installer is retired" \
    "${SCRIPT_DIR}/install.sh"

expect_exit_78 \
    "release builder requires explicit credentials and commit" \
    "${SCRIPT_DIR}/build-release-artifact.sh" \
    1.2.3 \
    42

/usr/bin/swift build \
    --package-path "${REPO_DIR}" \
    -c release \
    --product wordhand-release-auth >/dev/null
RELEASE_AUTH_TOOL="$(
    /usr/bin/swift build \
        --package-path "${REPO_DIR}" \
        -c release \
        --show-bin-path
)/wordhand-release-auth"
expect_exit_78 \
    "production manifest trust is deliberately unavailable" \
    "${RELEASE_AUTH_TOOL}" \
    production-key-status

PRIVATE_KEY_FIXTURE="${WORK_DIRECTORY}/private-key"
/usr/bin/printf '12345678901234567890123456789012' >"${PRIVATE_KEY_FIXTURE}"
/bin/chmod 600 "${PRIVATE_KEY_FIXTURE}"
expect_exit_78 \
    "fixture private key cannot activate production trust" \
    "${RELEASE_AUTH_TOOL}" \
    preflight-private-key \
    "${PRIVATE_KEY_FIXTURE}"

/bin/chmod +a "everyone allow read" "${PRIVATE_KEY_FIXTURE}"
set +e
ACL_REJECTION="$(
    "${RELEASE_AUTH_TOOL}" \
        preflight-private-key \
        "${PRIVATE_KEY_FIXTURE}" 2>&1
)"
ACL_STATUS=$?
set -e
if [ "${ACL_STATUS}" -ne 78 ] ||
    ! /usr/bin/grep -q 'insecurePrivateKeyFile' <<<"${ACL_REJECTION}"; then
    /bin/echo "mode-0600 private key with an extended ACL was accepted" >&2
    exit 1
fi

expect_exit_78 \
    "release builder requires an exact source commit before building" \
    /usr/bin/env \
    WORDHAND_RELEASE_TEAM_ID=TEAM123456 \
    WORDHAND_CODESIGN_IDENTITY="Developer ID Application: Wordhand Test (TEAM123456)" \
    WORDHAND_NOTARYTOOL_PROFILE=wordhand-notary \
    "${SCRIPT_DIR}/build-release-artifact.sh" \
    1.2.3 \
    42

if /usr/bin/grep -Eq \
    'curl|releases/download|api\.github\.com/repos/.*/releases' \
    "${SCRIPT_DIR}/install.sh"; then
    /bin/echo "legacy installer still contains an unauthenticated download path" >&2
    exit 1
fi
if /usr/bin/grep -Eq \
    '(--public-key|--key-id|--algorithm|fixture)' \
    "${REPO_DIR}/Sources/wordhand-release-auth/main.swift"; then
    /bin/echo "release authentication CLI exposes a trust-injection surface" >&2
    exit 1
fi

if [ -e "${REPO_DIR}/.github/workflows/release.yml" ]; then
    /bin/echo "legacy tag-triggered publisher still exists" >&2
    exit 1
fi
if /usr/bin/grep -REq \
    'action-gh-release|contents:[[:space:]]*write|gh[[:space:]]+release' \
    "${REPO_DIR}/.github/workflows"; then
    /bin/echo "a GitHub workflow still has a release-publication path" >&2
    exit 1
fi

if /usr/bin/grep -Eq \
    '(^|[^[:alnum:]_])(curl|gh[[:space:]]+release)([^[:alnum:]_]|$)|action-gh-release|contents:[[:space:]]*write' \
    "${SCRIPT_DIR}/build-release-artifact.sh"; then
    /bin/echo "release artifact builder must not publish or download artifacts" >&2
    exit 1
fi
if /usr/bin/grep -Eq '(^|/)(strip)([[:space:]]|$)' \
    "${SCRIPT_DIR}/build-release-artifact.sh"; then
    /bin/echo "release artifact builder must never strip after signing" >&2
    exit 1
fi

source_line() {
    local pattern="$1"
    /usr/bin/grep -nF "${pattern}" "${SCRIPT_DIR}/build-release-artifact.sh" |
        /usr/bin/head -1 |
        /usr/bin/cut -d: -f1
}

SIGNED_VERIFY_LINE="$(source_line '"${SCRIPT_DIR}/verify-release-app.sh" \')"
APP_NOTARY_LINE="$(source_line 'submit_for_notarization "${APP_ARCHIVE}"')"
APP_STAPLE_LINE="$(source_line 'stapler staple "${APP_PATH}"')"
APP_NOTARIZED_VERIFY_LINE="$(
    /usr/bin/grep -nF '"${SCRIPT_DIR}/verify-release-app.sh" \' \
        "${SCRIPT_DIR}/build-release-artifact.sh" |
        /usr/bin/tail -1 |
        /usr/bin/cut -d: -f1
)"
IMAGE_CREATE_LINE="$(source_line '/usr/bin/hdiutil create \')"
IMAGE_NOTARY_LINE="$(source_line 'submit_for_notarization "${DISK_IMAGE}"')"
IMAGE_STAPLE_LINE="$(source_line 'stapler staple "${DISK_IMAGE}"')"
IMAGE_VERIFY_LINE="$(source_line '"${SCRIPT_DIR}/verify-release-disk-image.sh" \')"
FINAL_HASH_LINE="$(source_line 'ASSET_SHA256="$(')"
MANIFEST_VERIFY_LINE="$(source_line '"${SCRIPT_DIR}/verify-release-manifest.sh" \')"
TRUST_STATUS_LINE="$(source_line '"${RELEASE_AUTH_TOOL}" production-key-status')"
PRIVATE_KEY_PREFLIGHT_LINE="$(source_line 'preflight-private-key \')"
APP_BUILD_LINE="$(source_line '"${SCRIPT_DIR}/build-app.sh"')"
MANIFEST_SIGN_LINE="$(source_line '    sign \')"
SIGNATURE_VERIFY_LINE="$(source_line '    verify \')"
FINAL_MOVE_LINE="$(source_line '/bin/mv "${FINAL_STAGING_DIRECTORY}" "${FINAL_DIRECTORY}"')"

if [ -z "${TRUST_STATUS_LINE}" ] ||
    [ -z "${PRIVATE_KEY_PREFLIGHT_LINE}" ] ||
    [ -z "${APP_BUILD_LINE}" ] ||
    [ -z "${SIGNED_VERIFY_LINE}" ] ||
    [ -z "${APP_NOTARY_LINE}" ] ||
    [ -z "${APP_STAPLE_LINE}" ] ||
    [ -z "${APP_NOTARIZED_VERIFY_LINE}" ] ||
    [ -z "${IMAGE_CREATE_LINE}" ] ||
    [ -z "${IMAGE_NOTARY_LINE}" ] ||
    [ -z "${IMAGE_STAPLE_LINE}" ] ||
    [ -z "${IMAGE_VERIFY_LINE}" ] ||
    [ -z "${FINAL_HASH_LINE}" ] ||
    [ -z "${MANIFEST_VERIFY_LINE}" ] ||
    [ -z "${MANIFEST_SIGN_LINE}" ] ||
    [ -z "${SIGNATURE_VERIFY_LINE}" ] ||
    [ -z "${FINAL_MOVE_LINE}" ] ||
    [ "${TRUST_STATUS_LINE}" -ge "${PRIVATE_KEY_PREFLIGHT_LINE}" ] ||
    [ "${PRIVATE_KEY_PREFLIGHT_LINE}" -ge "${APP_BUILD_LINE}" ] ||
    [ "${SIGNED_VERIFY_LINE}" -ge "${APP_NOTARY_LINE}" ] ||
    [ "${APP_NOTARY_LINE}" -ge "${APP_STAPLE_LINE}" ] ||
    [ "${APP_STAPLE_LINE}" -ge "${APP_NOTARIZED_VERIFY_LINE}" ] ||
    [ "${APP_NOTARIZED_VERIFY_LINE}" -ge "${IMAGE_CREATE_LINE}" ] ||
    [ "${IMAGE_CREATE_LINE}" -ge "${IMAGE_NOTARY_LINE}" ] ||
    [ "${IMAGE_NOTARY_LINE}" -ge "${IMAGE_STAPLE_LINE}" ] ||
    [ "${IMAGE_STAPLE_LINE}" -ge "${IMAGE_VERIFY_LINE}" ] ||
    [ "${IMAGE_VERIFY_LINE}" -ge "${FINAL_HASH_LINE}" ] ||
    [ "${FINAL_HASH_LINE}" -ge "${MANIFEST_VERIFY_LINE}" ] ||
    [ "${MANIFEST_VERIFY_LINE}" -ge "${MANIFEST_SIGN_LINE}" ] ||
    [ "${MANIFEST_SIGN_LINE}" -ge "${SIGNATURE_VERIFY_LINE}" ] ||
    [ "${SIGNATURE_VERIFY_LINE}" -ge "${FINAL_MOVE_LINE}" ]; then
    /bin/echo "release artifact operations are not in the fail-closed order" >&2
    exit 1
fi

VALID_VOLUME="${WORK_DIRECTORY}/valid-volume"
/bin/mkdir -p "${VALID_VOLUME}/Wordhand.app"
/bin/ln -s /Applications "${VALID_VOLUME}/Applications"
expect_success \
    "exact release volume layout" \
    "${SCRIPT_DIR}/verify-release-volume-layout.sh" \
    "${VALID_VOLUME}"

/usr/bin/touch "${VALID_VOLUME}/unexpected-file"
expect_exit_78 \
    "release volume with an extra file" \
    "${SCRIPT_DIR}/verify-release-volume-layout.sh" \
    "${VALID_VOLUME}"
/bin/rm "${VALID_VOLUME}/unexpected-file"

/bin/rm "${VALID_VOLUME}/Applications"
/bin/ln -s /tmp "${VALID_VOLUME}/Applications"
expect_exit_78 \
    "release volume with a redirected Applications link" \
    "${SCRIPT_DIR}/verify-release-volume-layout.sh" \
    "${VALID_VOLUME}"

MANIFEST_ASSET="${WORK_DIRECTORY}/Wordhand-1.2.3-macOS-arm64.dmg"
MANIFEST_PATH="${MANIFEST_ASSET}.manifest.json"
SOURCE_COMMIT="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
REQUIREMENT_SHA256="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
/usr/bin/printf 'sealed artifact bytes' >"${MANIFEST_ASSET}"
MANIFEST_ASSET_SIZE="$(/usr/bin/stat -f '%z' "${MANIFEST_ASSET}")"
MANIFEST_ASSET_SHA256="$(
    /usr/bin/shasum -a 256 "${MANIFEST_ASSET}" |
        /usr/bin/awk '{print $1}'
)"
/usr/bin/printf '%s\n' \
    '{' \
    '  "schemaVersion": 1,' \
    '  "version": "1.2.3",' \
    '  "buildNumber": "42",' \
    "  \"sourceCommit\": \"${SOURCE_COMMIT}\"," \
    '  "architecture": "arm64",' \
    '  "minimumMacOS": "14.0",' \
    '  "bundleIdentifier": "com.valyou.wordhand",' \
    '  "teamIdentifier": "TEAM123456",' \
    "  \"designatedRequirementSHA256\": \"${REQUIREMENT_SHA256}\"," \
    '  "asset": {' \
    '    "name": "Wordhand-1.2.3-macOS-arm64.dmg",' \
    "    \"size\": ${MANIFEST_ASSET_SIZE}," \
    "    \"sha256\": \"${MANIFEST_ASSET_SHA256}\"" \
    '  }' \
    '}' >"${MANIFEST_PATH}"

expect_success \
    "manifest matches exact final bytes" \
    "${SCRIPT_DIR}/verify-release-manifest.sh" \
    "${MANIFEST_PATH}" \
    "${MANIFEST_ASSET}" \
    1.2.3 \
    42 \
    "${SOURCE_COMMIT}" \
    TEAM123456 \
    "${REQUIREMENT_SHA256}"

EXTRA_FIELD_MANIFEST="${WORK_DIRECTORY}/extra-field.manifest.json"
/bin/cp "${MANIFEST_PATH}" "${EXTRA_FIELD_MANIFEST}"
/usr/bin/plutil -insert unexpectedField -string rejected \
    "${EXTRA_FIELD_MANIFEST}"
expect_exit_78 \
    "manifest rejects an extra field" \
    "${SCRIPT_DIR}/verify-release-manifest.sh" \
    "${EXTRA_FIELD_MANIFEST}" \
    "${MANIFEST_ASSET}" \
    1.2.3 \
    42 \
    "${SOURCE_COMMIT}" \
    TEAM123456 \
    "${REQUIREMENT_SHA256}"

/usr/bin/printf 'tampered' >>"${MANIFEST_ASSET}"
expect_exit_78 \
    "manifest rejects tampered final bytes" \
    "${SCRIPT_DIR}/verify-release-manifest.sh" \
    "${MANIFEST_PATH}" \
    "${MANIFEST_ASSET}" \
    1.2.3 \
    42 \
    "${SOURCE_COMMIT}" \
    TEAM123456 \
    "${REQUIREMENT_SHA256}"

APP_FIXTURE="${WORK_DIRECTORY}/Wordhand.app"
/bin/mkdir -p "${APP_FIXTURE}/Contents/MacOS"
/bin/cp /usr/bin/true "${APP_FIXTURE}/Contents/MacOS/wordhand"
/usr/bin/plutil -create xml1 "${APP_FIXTURE}/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string com.valyou.wordhand \
    "${APP_FIXTURE}/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string wordhand \
    "${APP_FIXTURE}/Contents/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string APPL \
    "${APP_FIXTURE}/Contents/Info.plist"
/usr/bin/codesign \
    --force \
    --options runtime \
    --entitlements "${REPO_DIR}/Packaging/Wordhand.entitlements" \
    --sign - \
    "${APP_FIXTURE}" >/dev/null 2>&1

if ! /usr/bin/codesign -dv --verbose=4 "${APP_FIXTURE}" 2>&1 |
    "${SCRIPT_DIR}/release-signature-has-runtime.sh"; then
    /bin/echo "real codesign runtime flags were not recognized" >&2
    exit 1
fi
if /usr/bin/printf '%s\n' \
    'CodeDirectory v=20500 flags=0x2(adhoc)' |
    "${SCRIPT_DIR}/release-signature-has-runtime.sh"; then
    /bin/echo "non-runtime codesign flags were accepted" >&2
    exit 1
fi

expect_exit_78 \
    "ad-hoc app cannot masquerade as a public release" \
    /usr/bin/env \
    WORDHAND_RELEASE_TEAM_ID=TEAM123456 \
    "${SCRIPT_DIR}/verify-release-app.sh" \
    signed \
    "${APP_FIXTURE}"

/bin/echo "✓ unsafe public distribution paths are retired"
/bin/echo "✓ release identity, runtime, entitlement, and notarization policy is fail-closed"
