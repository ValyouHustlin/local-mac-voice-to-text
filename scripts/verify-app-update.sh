#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" && /bin/pwd)"

if [ "$#" -ne 3 ]; then
    /bin/echo "usage: verify-app-update.sh <development|release> <candidate.app> <installed.app>" >&2
    exit 64
fi

CHANNEL="$1"
CANDIDATE_APP="$2"
INSTALLED_APP="$3"

case "${CHANNEL}" in
    development)
        EXPECTED_IDENTIFIER="com.valyou.wordhand.dev"
        ;;
    release)
        EXPECTED_IDENTIFIER="com.valyou.wordhand"
        ;;
    *)
        /bin/echo "update identity rejected: unknown build channel" >&2
        exit 78
        ;;
esac

reject() {
    /bin/echo "update identity rejected: $1" >&2
    exit 78
}

bundle_identifier() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
        "$1/Contents/Info.plist" 2>/dev/null
}

team_identifier() {
    local value
    value="$(
        /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 |
            /usr/bin/sed -n 's/^TeamIdentifier=//p'
    )"
    if [ -z "${value}" ]; then
        value="not set"
    fi
    /bin/echo "${value}"
}

signed_identifier() {
    /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 |
        /usr/bin/sed -n 's/^Identifier=//p'
}

designated_requirement() {
    /usr/bin/codesign -d -r- "$1" 2>&1 |
        /usr/bin/sed -n \
            -e 's/^designated => //p' \
            -e 's/^# designated => //p'
}

if [ -L "${CANDIDATE_APP}" ] || [ ! -d "${CANDIDATE_APP}" ]; then
    reject "candidate is not a regular app bundle"
fi
if ! /usr/bin/codesign --verify --deep --strict "${CANDIDATE_APP}"; then
    reject "candidate signature is invalid"
fi

CANDIDATE_IDENTIFIER="$(bundle_identifier "${CANDIDATE_APP}")" ||
    reject "candidate bundle identifier is unavailable"
CANDIDATE_SIGNED_IDENTIFIER="$(signed_identifier "${CANDIDATE_APP}")" ||
    reject "candidate signed identifier is unavailable"
CANDIDATE_TEAM_IDENTIFIER="$(team_identifier "${CANDIDATE_APP}")"
CANDIDATE_REQUIREMENT="$(designated_requirement "${CANDIDATE_APP}")" ||
    reject "candidate designated requirement is unavailable"

INSTALLED_PRESENT=0
INSTALLED_IDENTIFIER=""
INSTALLED_SIGNED_IDENTIFIER=""
INSTALLED_TEAM_IDENTIFIER=""
INSTALLED_REQUIREMENT=""
if [ -e "${INSTALLED_APP}" ] || [ -L "${INSTALLED_APP}" ]; then
    INSTALLED_PRESENT=1
    if [ -L "${INSTALLED_APP}" ] || [ ! -d "${INSTALLED_APP}" ]; then
        reject "installed target is not a regular app bundle"
    fi
    if ! /usr/bin/codesign --verify --deep --strict "${INSTALLED_APP}"; then
        reject "installed app signature is invalid"
    fi
    INSTALLED_IDENTIFIER="$(bundle_identifier "${INSTALLED_APP}")" ||
        reject "installed bundle identifier is unavailable"
    INSTALLED_SIGNED_IDENTIFIER="$(signed_identifier "${INSTALLED_APP}")" ||
        reject "installed signed identifier is unavailable"
    INSTALLED_TEAM_IDENTIFIER="$(team_identifier "${INSTALLED_APP}")"
    INSTALLED_REQUIREMENT="$(designated_requirement "${INSTALLED_APP}")" ||
        reject "installed designated requirement is unavailable"
fi

"${SCRIPT_DIR}/verify-update-identity-policy.sh" \
    "${CHANNEL}" \
    "${EXPECTED_IDENTIFIER}" \
    "${CANDIDATE_IDENTIFIER}" \
    "${CANDIDATE_SIGNED_IDENTIFIER}" \
    "${CANDIDATE_TEAM_IDENTIFIER}" \
    "${CANDIDATE_REQUIREMENT}" \
    "${INSTALLED_PRESENT}" \
    "${INSTALLED_IDENTIFIER}" \
    "${INSTALLED_SIGNED_IDENTIFIER}" \
    "${INSTALLED_TEAM_IDENTIFIER}" \
    "${INSTALLED_REQUIREMENT}"

/bin/echo "✓ update identity matches ${EXPECTED_IDENTIFIER}"
