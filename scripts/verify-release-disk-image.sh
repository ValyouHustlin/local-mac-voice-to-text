#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" && /bin/pwd)"

if [ "$#" -ne 1 ]; then
    /bin/echo "usage: verify-release-disk-image.sh <Wordhand.dmg>" >&2
    exit 64
fi

DISK_IMAGE="$1"
MOUNT_DIRECTORY="$(/usr/bin/mktemp -d /tmp/wordhand-release-mount.XXXXXX)"
ATTACHED=0

cleanup() {
    if [ "${ATTACHED}" = "1" ]; then
        /usr/bin/hdiutil detach "${MOUNT_DIRECTORY}" >/dev/null 2>&1 || true
    fi
    /bin/rmdir "${MOUNT_DIRECTORY}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

reject() {
    /bin/echo "release disk image rejected: $1" >&2
    exit 78
}

if [ -L "${DISK_IMAGE}" ] || [ ! -f "${DISK_IMAGE}" ]; then
    reject "candidate is not a regular disk image"
fi
if ! /usr/bin/codesign --verify --strict "${DISK_IMAGE}"; then
    reject "disk image signature is invalid"
fi
if ! /usr/bin/xcrun stapler validate "${DISK_IMAGE}" >/dev/null 2>&1; then
    reject "disk image notarization ticket is invalid"
fi
if ! /usr/sbin/spctl \
    --assess \
    --type open \
    --context context:primary-signature \
    --verbose=4 \
    "${DISK_IMAGE}" >/dev/null 2>&1; then
    reject "Gatekeeper did not accept the disk image"
fi
if ! /usr/bin/hdiutil attach \
    -readonly \
    -nobrowse \
    -mountpoint "${MOUNT_DIRECTORY}" \
    "${DISK_IMAGE}" >/dev/null; then
    reject "disk image could not be mounted read-only"
fi
ATTACHED=1

"${SCRIPT_DIR}/verify-release-volume-layout.sh" "${MOUNT_DIRECTORY}"

"${SCRIPT_DIR}/verify-release-app.sh" \
    notarized \
    "${MOUNT_DIRECTORY}/Wordhand.app" >/dev/null

/bin/echo "✓ notarized release disk image contains one verified Wordhand.app"
