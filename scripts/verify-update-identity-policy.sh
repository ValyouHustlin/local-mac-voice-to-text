#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 11 ]; then
    /bin/echo "usage: verify-update-identity-policy.sh <channel> <expected-id> <candidate-plist-id> <candidate-signed-id> <candidate-team-id> <candidate-requirement> <installed-present> <installed-plist-id> <installed-signed-id> <installed-team-id> <installed-requirement>" >&2
    exit 64
fi

CHANNEL="$1"
EXPECTED_IDENTIFIER="$2"
CANDIDATE_IDENTIFIER="$3"
CANDIDATE_SIGNED_IDENTIFIER="$4"
CANDIDATE_TEAM_IDENTIFIER="$5"
CANDIDATE_REQUIREMENT="$6"
INSTALLED_PRESENT="$7"
INSTALLED_IDENTIFIER="$8"
INSTALLED_SIGNED_IDENTIFIER="$9"
INSTALLED_TEAM_IDENTIFIER="${10}"
INSTALLED_REQUIREMENT="${11}"

reject() {
    /bin/echo "update identity rejected: $1" >&2
    exit 78
}

case "${CHANNEL}" in
    development|release) ;;
    *) reject "unknown build channel" ;;
esac

if [ "${CANDIDATE_IDENTIFIER}" != "${EXPECTED_IDENTIFIER}" ]; then
    reject "candidate bundle identifier does not match ${EXPECTED_IDENTIFIER}"
fi
if [ "${CANDIDATE_SIGNED_IDENTIFIER}" != "${EXPECTED_IDENTIFIER}" ]; then
    reject "candidate signed identifier does not match ${EXPECTED_IDENTIFIER}"
fi
if [ -z "${CANDIDATE_REQUIREMENT}" ]; then
    reject "candidate designated requirement is unavailable"
fi
if [ "${CHANNEL}" = "release" ]; then
    case "${CANDIDATE_TEAM_IDENTIFIER}" in
        ""|"not set") reject "release candidate has no Developer ID Team ID" ;;
    esac
    if [ "${INSTALLED_PRESENT}" = "0" ]; then
        reject "fresh release installation requires the notarized distribution path"
    fi
fi

case "${INSTALLED_PRESENT}" in
    0)
        exit 0
        ;;
    1)
        ;;
    *)
        reject "installed-app presence must be 0 or 1"
        ;;
esac

if [ "${INSTALLED_IDENTIFIER}" != "${EXPECTED_IDENTIFIER}" ]; then
    reject "installed bundle identifier does not match ${EXPECTED_IDENTIFIER}"
fi
if [ "${INSTALLED_SIGNED_IDENTIFIER}" != "${EXPECTED_IDENTIFIER}" ]; then
    reject "installed signed identifier does not match ${EXPECTED_IDENTIFIER}"
fi
if [ -z "${INSTALLED_REQUIREMENT}" ]; then
    reject "installed designated requirement is unavailable"
fi
if [ "${CANDIDATE_TEAM_IDENTIFIER}" != "${INSTALLED_TEAM_IDENTIFIER}" ]; then
    reject "candidate Team ID does not match the installed app"
fi
if [ "${CANDIDATE_REQUIREMENT}" != "${INSTALLED_REQUIREMENT}" ]; then
    reject "candidate designated requirement does not match the installed app"
fi
