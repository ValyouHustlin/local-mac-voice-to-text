#!/usr/bin/env bash
# Persist the display name of an existing Keychain code-signing identity.

set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    /bin/echo 'usage: scripts/configure-local-signing.sh "Signing Identity Name"' >&2
    exit 64
fi

SIGNING_IDENTITY="$1"
SIGNING_CONFIG="${WORDHAND_SIGNING_CONFIG:-${HOME}/Library/Application Support/Wordhand/signing-identity}"
SIGNING_DIRECTORY="$(/usr/bin/dirname "${SIGNING_CONFIG}")"

case "${SIGNING_IDENTITY}" in
    *$'\n'*|*$'\r'*)
        /bin/echo "signing identity must be a single line" >&2
        exit 64
        ;;
esac

if ! /usr/bin/security find-identity -v -p codesigning |
    /usr/bin/grep -F "\"${SIGNING_IDENTITY}\"" >/dev/null; then
    /bin/echo "No matching code-signing identity exists in the current Keychain." >&2
    /bin/echo "Create or import the identity first, then run this command again." >&2
    exit 1
fi

/bin/mkdir -p "${SIGNING_DIRECTORY}"
/bin/chmod 700 "${SIGNING_DIRECTORY}"
/usr/bin/printf '%s\n' "${SIGNING_IDENTITY}" > "${SIGNING_CONFIG}"
/bin/chmod 600 "${SIGNING_CONFIG}"

/bin/echo "Wordhand will sign future local builds with: ${SIGNING_IDENTITY}"
