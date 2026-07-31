#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 5 ]; then
    /bin/echo "usage: verify-release-package-input-policy.sh <version> <build-number> <team-id> <signing-identity> <notary-profile>" >&2
    exit 64
fi

VERSION="$1"
BUILD_NUMBER="$2"
TEAM_IDENTIFIER="$3"
SIGNING_IDENTITY="$4"
NOTARY_PROFILE="$5"

reject() {
    /bin/echo "release packaging rejected: $1" >&2
    exit 78
}

if ! [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    reject "version must be a numeric three-part release"
fi
if ! [[ "${BUILD_NUMBER}" =~ ^[1-9][0-9]*$ ]]; then
    reject "build number must be a positive integer"
fi
if ! [[ "${TEAM_IDENTIFIER}" =~ ^[A-Z0-9]{10}$ ]]; then
    reject "Team ID must contain exactly ten uppercase letters or digits"
fi
case "${SIGNING_IDENTITY}" in
    *$'\n'*|*$'\r'*) reject "signing identity must be a single line" ;;
esac
case "${SIGNING_IDENTITY}" in
    "Developer ID Application: "*" (${TEAM_IDENTIFIER})") ;;
    *) reject "signing identity does not name the configured Developer ID team" ;;
esac
if ! [[ "${NOTARY_PROFILE}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
    reject "notary profile name is invalid"
fi
