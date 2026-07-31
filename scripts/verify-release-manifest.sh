#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 7 ]; then
    /bin/echo "usage: verify-release-manifest.sh <manifest.json> <asset.dmg> <version> <build-number> <source-commit> <team-id> <designated-requirement-sha256>" >&2
    exit 64
fi

MANIFEST_PATH="$1"
ASSET_PATH="$2"
EXPECTED_VERSION="$3"
EXPECTED_BUILD_NUMBER="$4"
EXPECTED_SOURCE_COMMIT="$5"
EXPECTED_TEAM_IDENTIFIER="$6"
EXPECTED_REQUIREMENT_SHA256="$7"

reject() {
    /bin/echo "release manifest rejected: $1" >&2
    exit 78
}

if [ -L "${MANIFEST_PATH}" ] || [ ! -f "${MANIFEST_PATH}" ]; then
    reject "manifest is not a regular file"
fi
if [ -L "${ASSET_PATH}" ] || [ ! -f "${ASSET_PATH}" ]; then
    reject "asset is not a regular file"
fi
if ! /usr/bin/plutil -convert xml1 -o /dev/null \
    "${MANIFEST_PATH}" >/dev/null 2>&1; then
    reject "manifest is not valid JSON"
fi

manifest_value() {
    /usr/bin/plutil -extract "$1" raw -o - "${MANIFEST_PATH}" 2>/dev/null
}

if [ "$(manifest_value schemaVersion || true)" != "1" ]; then
    reject "schema version is not 1"
fi
if [ "$(manifest_value version || true)" != "${EXPECTED_VERSION}" ]; then
    reject "version does not match"
fi
if [ "$(manifest_value buildNumber || true)" != "${EXPECTED_BUILD_NUMBER}" ]; then
    reject "build number does not match"
fi
if [ "$(manifest_value sourceCommit || true)" != "${EXPECTED_SOURCE_COMMIT}" ]; then
    reject "source commit does not match"
fi
if [ "$(manifest_value architecture || true)" != "arm64" ]; then
    reject "architecture is not arm64"
fi
if [ "$(manifest_value minimumMacOS || true)" != "14.0" ]; then
    reject "minimum macOS version is not 14.0"
fi
if [ "$(manifest_value bundleIdentifier || true)" != "com.valyou.wordhand" ]; then
    reject "bundle identifier does not match"
fi
if [ "$(manifest_value teamIdentifier || true)" != "${EXPECTED_TEAM_IDENTIFIER}" ]; then
    reject "Team ID does not match"
fi
if [ "$(
    manifest_value designatedRequirementSHA256 || true
)" != "${EXPECTED_REQUIREMENT_SHA256}" ]; then
    reject "designated requirement digest does not match"
fi

EXPECTED_ASSET_NAME="$(/usr/bin/basename "${ASSET_PATH}")"
if [ "$(manifest_value asset.name || true)" != "${EXPECTED_ASSET_NAME}" ]; then
    reject "asset name does not match"
fi
EXPECTED_ASSET_SIZE="$(/usr/bin/stat -f '%z' "${ASSET_PATH}")"
if [ "$(manifest_value asset.size || true)" != "${EXPECTED_ASSET_SIZE}" ]; then
    reject "asset size does not match"
fi
EXPECTED_ASSET_SHA256="$(
    /usr/bin/shasum -a 256 "${ASSET_PATH}" |
        /usr/bin/awk '{print $1}'
)"
if [ "$(manifest_value asset.sha256 || true)" != "${EXPECTED_ASSET_SHA256}" ]; then
    reject "asset digest does not match"
fi

KEY_COUNT="$(
    /usr/bin/plutil -convert xml1 -o - "${MANIFEST_PATH}" |
        /usr/bin/grep -c '<key>'
)"
if [ "${KEY_COUNT}" != "13" ]; then
    reject "manifest contains an unexpected field"
fi

/bin/echo "✓ release manifest matches the final artifact bytes"
