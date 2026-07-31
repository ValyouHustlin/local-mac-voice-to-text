#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" && /bin/pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && /bin/pwd)"

if [ "$#" -ne 2 ]; then
    /bin/echo "usage: build-release-artifact.sh <version> <build-number>" >&2
    exit 64
fi

VERSION="$1"
BUILD_NUMBER="$2"
TEAM_IDENTIFIER="${WORDHAND_RELEASE_TEAM_ID:-}"
SIGNING_IDENTITY="${WORDHAND_CODESIGN_IDENTITY:-}"
NOTARY_PROFILE="${WORDHAND_NOTARYTOOL_PROFILE:-}"
EXPECTED_COMMIT="${WORDHAND_RELEASE_COMMIT:-}"
OUTPUT_PARENT="${WORDHAND_RELEASE_OUTPUT_DIRECTORY:-${REPO_DIR}/dist/releases}"

reject() {
    /bin/echo "release packaging rejected: $1" >&2
    exit 78
}

"${SCRIPT_DIR}/verify-release-package-input-policy.sh" \
    "${VERSION}" \
    "${BUILD_NUMBER}" \
    "${TEAM_IDENTIFIER}" \
    "${SIGNING_IDENTITY}" \
    "${NOTARY_PROFILE}"

if ! [[ "${EXPECTED_COMMIT}" =~ ^[0-9a-f]{40}$ ]]; then
    reject "WORDHAND_RELEASE_COMMIT must be a full lowercase commit hash"
fi
CURRENT_COMMIT="$(/usr/bin/git -C "${REPO_DIR}" rev-parse HEAD)"
if [ "${CURRENT_COMMIT}" != "${EXPECTED_COMMIT}" ]; then
    reject "release commit does not match the checked-out source"
fi
if [ -n "$(
    /usr/bin/git -C "${REPO_DIR}" status \
        --porcelain \
        --untracked-files=all
)" ]; then
    reject "release source checkout must be completely clean"
fi

RELEASE_NAME="Wordhand-${VERSION}-${BUILD_NUMBER}"
FINAL_DIRECTORY="${OUTPUT_PARENT}/${RELEASE_NAME}"
ASSET_NAME="Wordhand-${VERSION}-macOS-arm64.dmg"
MANIFEST_NAME="${ASSET_NAME}.manifest.json"

if [ -e "${FINAL_DIRECTORY}" ] || [ -L "${FINAL_DIRECTORY}" ]; then
    reject "release output already exists"
fi
/bin/mkdir -p "${OUTPUT_PARENT}"

WORK_DIRECTORY="$(/usr/bin/mktemp -d /tmp/wordhand-release-build.XXXXXX)"
FINAL_STAGING_DIRECTORY=""

cleanup() {
    /bin/rm -rf "${WORK_DIRECTORY}"
    if [ -n "${FINAL_STAGING_DIRECTORY}" ] &&
        [ -d "${FINAL_STAGING_DIRECTORY}" ]; then
        /bin/rm -rf "${FINAL_STAGING_DIRECTORY}"
    fi
}
trap cleanup EXIT

FINAL_STAGING_DIRECTORY="$(
    /usr/bin/mktemp -d "${OUTPUT_PARENT}/.wordhand-release.XXXXXX"
)"
APP_PATH="${WORK_DIRECTORY}/Wordhand.app"
APP_ARCHIVE="${WORK_DIRECTORY}/Wordhand.zip"
DISK_ROOT="${WORK_DIRECTORY}/disk-root"
DISK_IMAGE="${WORK_DIRECTORY}/${ASSET_NAME}"
APP_NOTARY_RECEIPT="${WORK_DIRECTORY}/app-notary.json"
IMAGE_NOTARY_RECEIPT="${WORK_DIRECTORY}/image-notary.json"

submit_for_notarization() {
    local artifact="$1"
    local receipt="$2"
    local status

    if ! /usr/bin/xcrun notarytool submit \
        "${artifact}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait \
        --output-format json >"${receipt}"; then
        reject "Apple notarization submission failed"
    fi
    status="$(
        /usr/bin/plutil -extract status raw -o - "${receipt}" 2>/dev/null ||
            true
    )"
    if [ "${status}" != "Accepted" ]; then
        reject "Apple notarization did not accept the artifact"
    fi
}

/usr/bin/env \
    WORDHAND_BUILD_CHANNEL=release \
    WORDHAND_BUILD_ARCHITECTURE=arm64 \
    WORDHAND_VERSION="${VERSION}" \
    WORDHAND_BUILD_NUMBER="${BUILD_NUMBER}" \
    WORDHAND_CODESIGN_IDENTITY="${SIGNING_IDENTITY}" \
    WORDHAND_APP_OUTPUT="${APP_PATH}" \
    "${SCRIPT_DIR}/build-app.sh"

/usr/bin/env \
    WORDHAND_RELEASE_TEAM_ID="${TEAM_IDENTIFIER}" \
    "${SCRIPT_DIR}/verify-release-app.sh" \
    signed \
    "${APP_PATH}"

/usr/bin/ditto \
    -c \
    -k \
    --keepParent \
    "${APP_PATH}" \
    "${APP_ARCHIVE}"
submit_for_notarization "${APP_ARCHIVE}" "${APP_NOTARY_RECEIPT}"
/usr/bin/xcrun stapler staple "${APP_PATH}"

/usr/bin/env \
    WORDHAND_RELEASE_TEAM_ID="${TEAM_IDENTIFIER}" \
    "${SCRIPT_DIR}/verify-release-app.sh" \
    notarized \
    "${APP_PATH}"

/bin/mkdir -p "${DISK_ROOT}"
/usr/bin/ditto "${APP_PATH}" "${DISK_ROOT}/Wordhand.app"
/bin/ln -s /Applications "${DISK_ROOT}/Applications"
/usr/bin/hdiutil create \
    -volname Wordhand \
    -srcfolder "${DISK_ROOT}" \
    -format UDZO \
    -ov \
    "${DISK_IMAGE}" >/dev/null
/usr/bin/codesign \
    --force \
    --timestamp \
    --sign "${SIGNING_IDENTITY}" \
    "${DISK_IMAGE}"
submit_for_notarization "${DISK_IMAGE}" "${IMAGE_NOTARY_RECEIPT}"
/usr/bin/xcrun stapler staple "${DISK_IMAGE}"

/usr/bin/env \
    WORDHAND_RELEASE_TEAM_ID="${TEAM_IDENTIFIER}" \
    "${SCRIPT_DIR}/verify-release-disk-image.sh" \
    "${DISK_IMAGE}"

ASSET_SIZE="$(/usr/bin/stat -f '%z' "${DISK_IMAGE}")"
ASSET_SHA256="$(
    /usr/bin/shasum -a 256 "${DISK_IMAGE}" |
        /usr/bin/awk '{print $1}'
)"
DESIGNATED_REQUIREMENT="$(
    /usr/bin/codesign -d -r- "${APP_PATH}" 2>&1 |
        /usr/bin/sed -n 's/^designated => //p'
)"
if [ -z "${DESIGNATED_REQUIREMENT}" ]; then
    reject "designated signing requirement is unavailable"
fi
DESIGNATED_REQUIREMENT_SHA256="$(
    /usr/bin/printf '%s' "${DESIGNATED_REQUIREMENT}" |
        /usr/bin/shasum -a 256 |
        /usr/bin/awk '{print $1}'
)"

/usr/bin/ditto "${DISK_IMAGE}" "${FINAL_STAGING_DIRECTORY}/${ASSET_NAME}"
/usr/bin/printf '%s\n' \
    '{' \
    '  "schemaVersion": 1,' \
    "  \"version\": \"${VERSION}\"," \
    "  \"buildNumber\": \"${BUILD_NUMBER}\"," \
    "  \"sourceCommit\": \"${CURRENT_COMMIT}\"," \
    '  "architecture": "arm64",' \
    '  "minimumMacOS": "14.0",' \
    '  "bundleIdentifier": "com.valyou.wordhand",' \
    "  \"teamIdentifier\": \"${TEAM_IDENTIFIER}\"," \
    "  \"designatedRequirementSHA256\": \"${DESIGNATED_REQUIREMENT_SHA256}\"," \
    '  "asset": {' \
    "    \"name\": \"${ASSET_NAME}\"," \
    "    \"size\": ${ASSET_SIZE}," \
    "    \"sha256\": \"${ASSET_SHA256}\"" \
    '  }' \
    '}' >"${FINAL_STAGING_DIRECTORY}/${MANIFEST_NAME}"

"${SCRIPT_DIR}/verify-release-manifest.sh" \
    "${FINAL_STAGING_DIRECTORY}/${MANIFEST_NAME}" \
    "${FINAL_STAGING_DIRECTORY}/${ASSET_NAME}" \
    "${VERSION}" \
    "${BUILD_NUMBER}" \
    "${CURRENT_COMMIT}" \
    "${TEAM_IDENTIFIER}" \
    "${DESIGNATED_REQUIREMENT_SHA256}"

/bin/mv "${FINAL_STAGING_DIRECTORY}" "${FINAL_DIRECTORY}"

/bin/echo "Built notarized release artifact:"
/bin/echo "  ${FINAL_DIRECTORY}/${ASSET_NAME}"
/bin/echo "Integrity manifest:"
/bin/echo "  ${FINAL_DIRECTORY}/${MANIFEST_NAME}"
/bin/echo "No release was published or installed."
