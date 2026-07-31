#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 14 ]; then
    /bin/echo "usage: verify-release-artifact-policy.sh <signed|notarized> <expected-team-id> <plist-id> <signed-id> <team-id> <authority> <architectures> <runtime> <timestamp> <audio-input> <entitlement-count> <get-task-allow> <staple-valid> <gatekeeper-accepted>" >&2
    exit 64
fi

PHASE="$1"
EXPECTED_TEAM_IDENTIFIER="$2"
PLIST_IDENTIFIER="$3"
SIGNED_IDENTIFIER="$4"
TEAM_IDENTIFIER="$5"
AUTHORITY="$6"
ARCHITECTURES="$7"
HARDENED_RUNTIME="$8"
SECURE_TIMESTAMP="$9"
AUDIO_INPUT_ENTITLEMENT="${10}"
ENTITLEMENT_COUNT="${11}"
GET_TASK_ALLOW="${12}"
STAPLE_VALID="${13}"
GATEKEEPER_ACCEPTED="${14}"

reject() {
    /bin/echo "release artifact rejected: $1" >&2
    exit 78
}

case "${PHASE}" in
    signed|notarized) ;;
    *) reject "unknown verification phase" ;;
esac

if ! [[ "${EXPECTED_TEAM_IDENTIFIER}" =~ ^[A-Z0-9]{10}$ ]]; then
    reject "expected Team ID is invalid"
fi

for boolean_value in \
    "${HARDENED_RUNTIME}" \
    "${SECURE_TIMESTAMP}" \
    "${AUDIO_INPUT_ENTITLEMENT}" \
    "${GET_TASK_ALLOW}" \
    "${STAPLE_VALID}" \
    "${GATEKEEPER_ACCEPTED}"; do
    case "${boolean_value}" in
        0|1) ;;
        *) reject "verification facts must be 0 or 1" ;;
    esac
done

if [ "${PLIST_IDENTIFIER}" != "com.valyou.wordhand" ]; then
    reject "plist identifier is not com.valyou.wordhand"
fi
if [ "${SIGNED_IDENTIFIER}" != "com.valyou.wordhand" ]; then
    reject "signed identifier is not com.valyou.wordhand"
fi
if [ "${TEAM_IDENTIFIER}" != "${EXPECTED_TEAM_IDENTIFIER}" ]; then
    reject "Team ID does not match the configured release team"
fi
case "${AUTHORITY}" in
    "Developer ID Application: "*" (${EXPECTED_TEAM_IDENTIFIER})") ;;
    *) reject "signing authority is not the configured Developer ID Application identity" ;;
esac
if [ "${ARCHITECTURES}" != "arm64" ]; then
    reject "release executable is not arm64-only"
fi
if [ "${HARDENED_RUNTIME}" != "1" ]; then
    reject "hardened runtime is missing"
fi
if [ "${SECURE_TIMESTAMP}" != "1" ]; then
    reject "secure timestamp is missing"
fi
if [ "${AUDIO_INPUT_ENTITLEMENT}" != "1" ]; then
    reject "microphone entitlement is missing"
fi
if [ "${ENTITLEMENT_COUNT}" != "1" ]; then
    reject "release app must contain only the microphone entitlement"
fi
if [ "${GET_TASK_ALLOW}" != "0" ]; then
    reject "debug entitlement is enabled"
fi

if [ "${PHASE}" = "notarized" ]; then
    if [ "${STAPLE_VALID}" != "1" ]; then
        reject "notarization ticket is not stapled and valid"
    fi
    if [ "${GATEKEEPER_ACCEPTED}" != "1" ]; then
        reject "Gatekeeper did not accept the app"
    fi
fi
