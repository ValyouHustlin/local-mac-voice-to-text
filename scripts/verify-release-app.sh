#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" && /bin/pwd)"

if [ "$#" -ne 2 ]; then
    /bin/echo "usage: verify-release-app.sh <signed|notarized> <Wordhand.app>" >&2
    exit 64
fi

PHASE="$1"
APP_PATH="$2"
EXPECTED_TEAM_IDENTIFIER="${WORDHAND_RELEASE_TEAM_ID:-}"

reject() {
    /bin/echo "release app rejected: $1" >&2
    exit 78
}

case "${PHASE}" in
    signed|notarized) ;;
    *) reject "unknown verification phase" ;;
esac

if [ -L "${APP_PATH}" ] || [ ! -d "${APP_PATH}" ]; then
    reject "candidate is not a regular app bundle"
fi
if ! /usr/bin/codesign --verify --deep --strict "${APP_PATH}"; then
    reject "code signature is invalid"
fi

PLIST_IDENTIFIER="$(
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
        "${APP_PATH}/Contents/Info.plist" 2>/dev/null
)" || reject "plist identifier is unavailable"

SIGNATURE_DETAILS="$(
    /usr/bin/codesign -dv --verbose=4 "${APP_PATH}" 2>&1
)" || reject "signature details are unavailable"
SIGNED_IDENTIFIER="$(
    /bin/echo "${SIGNATURE_DETAILS}" |
        /usr/bin/sed -n 's/^Identifier=//p'
)"
TEAM_IDENTIFIER="$(
    /bin/echo "${SIGNATURE_DETAILS}" |
        /usr/bin/sed -n 's/^TeamIdentifier=//p'
)"
AUTHORITY="$(
    /bin/echo "${SIGNATURE_DETAILS}" |
        /usr/bin/sed -n 's/^Authority=//p' |
        /usr/bin/head -1
)"
ARCHITECTURES="$(
    /usr/bin/lipo -archs "${APP_PATH}/Contents/MacOS/wordhand" 2>/dev/null
)" || reject "release executable architecture is unavailable"

HARDENED_RUNTIME=0
if /usr/bin/printf '%s\n' "${SIGNATURE_DETAILS}" |
    "${SCRIPT_DIR}/release-signature-has-runtime.sh"; then
    HARDENED_RUNTIME=1
fi
SECURE_TIMESTAMP=0
if /bin/echo "${SIGNATURE_DETAILS}" |
    /usr/bin/grep -Eq '^Timestamp=.+$' &&
    ! /bin/echo "${SIGNATURE_DETAILS}" |
        /usr/bin/grep -Eq '^Timestamp=none$'; then
    SECURE_TIMESTAMP=1
fi

ENTITLEMENTS_PLIST="$(/usr/bin/mktemp /tmp/wordhand-release-entitlements.XXXXXX)"
trap '/bin/rm -f "${ENTITLEMENTS_PLIST}"' EXIT
if ! /usr/bin/codesign -d --entitlements :- "${APP_PATH}" \
    >"${ENTITLEMENTS_PLIST}" 2>/dev/null; then
    reject "signed entitlements are unavailable"
fi

AUDIO_INPUT_ENTITLEMENT=0
if [ "$(
    /usr/bin/plutil -extract com.apple.security.device.audio-input raw \
        -o - "${ENTITLEMENTS_PLIST}" 2>/dev/null || true
)" = "true" ]; then
    AUDIO_INPUT_ENTITLEMENT=1
fi
ENTITLEMENT_COUNT="$(
    (
        /usr/bin/plutil -p "${ENTITLEMENTS_PLIST}" 2>/dev/null |
            /usr/bin/grep -c ' => '
    ) || true
)"
GET_TASK_ALLOW=0
if [ "$(
    /usr/bin/plutil -extract com.apple.security.get-task-allow raw \
        -o - "${ENTITLEMENTS_PLIST}" 2>/dev/null || true
)" = "true" ]; then
    GET_TASK_ALLOW=1
fi

STAPLE_VALID=0
GATEKEEPER_ACCEPTED=0
if [ "${PHASE}" = "notarized" ]; then
    if /usr/bin/xcrun stapler validate "${APP_PATH}" >/dev/null 2>&1; then
        STAPLE_VALID=1
    fi
    if /usr/sbin/spctl --assess --type execute --verbose=4 \
        "${APP_PATH}" >/dev/null 2>&1; then
        GATEKEEPER_ACCEPTED=1
    fi
fi

"${SCRIPT_DIR}/verify-release-artifact-policy.sh" \
    "${PHASE}" \
    "${EXPECTED_TEAM_IDENTIFIER}" \
    "${PLIST_IDENTIFIER}" \
    "${SIGNED_IDENTIFIER}" \
    "${TEAM_IDENTIFIER:-not set}" \
    "${AUTHORITY}" \
    "${ARCHITECTURES}" \
    "${HARDENED_RUNTIME}" \
    "${SECURE_TIMESTAMP}" \
    "${AUDIO_INPUT_ENTITLEMENT}" \
    "${ENTITLEMENT_COUNT}" \
    "${GET_TASK_ALLOW}" \
    "${STAPLE_VALID}" \
    "${GATEKEEPER_ACCEPTED}"

/bin/echo "✓ release app satisfies ${PHASE} policy"
