#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 1 ]; then
    /bin/echo "usage: verify-release-volume-layout.sh <mounted-volume>" >&2
    exit 64
fi

VOLUME_PATH="$1"

reject() {
    /bin/echo "release volume rejected: $1" >&2
    exit 78
}

if [ -L "${VOLUME_PATH}" ] || [ ! -d "${VOLUME_PATH}" ]; then
    reject "volume path is not a regular directory"
fi

ENTRY_COUNT="$(
    /usr/bin/find "${VOLUME_PATH}" \
        -mindepth 1 \
        -maxdepth 1 \
        -print |
        /usr/bin/wc -l |
        /usr/bin/tr -d ' '
)"
if [ "${ENTRY_COUNT}" != "2" ]; then
    reject "volume must contain only Wordhand.app and the Applications link"
fi
if [ -L "${VOLUME_PATH}/Wordhand.app" ] ||
    [ ! -d "${VOLUME_PATH}/Wordhand.app" ]; then
    reject "Wordhand.app is not a regular top-level app bundle"
fi
if [ ! -L "${VOLUME_PATH}/Applications" ] ||
    [ "$(/usr/bin/readlink "${VOLUME_PATH}/Applications")" != "/Applications" ]; then
    reject "Applications must be the exact /Applications convenience link"
fi
