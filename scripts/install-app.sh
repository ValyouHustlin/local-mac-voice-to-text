#!/usr/bin/env bash
# Install the locally built app without requiring administrator access.

set -euo pipefail

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" && /bin/pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && /bin/pwd)"
SOURCE_APP="${WORDHAND_APP_OUTPUT:-${REPO_DIR}/dist/Wordhand.app}"
USER_APP_DIR="${WORDHAND_INSTALL_DIRECTORY:-${HOME}/Applications}"
TARGET_APP="${USER_APP_DIR}/Wordhand.app"
ENABLE_LOGIN=false

for argument in "$@"; do
    case "${argument}" in
        --launch-at-login) ENABLE_LOGIN=true ;;
        *)
            /bin/echo "unknown option: ${argument}" >&2
            /bin/echo "usage: scripts/install-app.sh [--launch-at-login]" >&2
            exit 64
            ;;
    esac
done

"${SCRIPT_DIR}/build-app.sh"

if /usr/bin/pgrep -x wordhand >/dev/null 2>&1; then
    /bin/echo "Stopping the current Wordhand process for a clean update…"
    /usr/bin/pkill -TERM -x wordhand
    for _ in 1 2 3 4 5; do
        if ! /usr/bin/pgrep -x wordhand >/dev/null 2>&1; then
            break
        fi
        /bin/sleep 1
    done
    if /usr/bin/pgrep -x wordhand >/dev/null 2>&1; then
        /bin/echo "Wordhand did not stop cleanly; installation aborted." >&2
        exit 1
    fi
fi

/bin/mkdir -p "${USER_APP_DIR}"
STAGING_APP="${USER_APP_DIR}/.Wordhand.app.staging.$$"
trap '/bin/rm -rf "${STAGING_APP}"' EXIT
/usr/bin/ditto "${SOURCE_APP}" "${STAGING_APP}"
/usr/bin/codesign --verify --deep --strict "${STAGING_APP}"

if [ -e "${TARGET_APP}" ]; then
    BACKUP_APP="${USER_APP_DIR}/Wordhand.backup.$(/bin/date +%Y%m%d-%H%M%S).app"
    /bin/mv "${TARGET_APP}" "${BACKUP_APP}"
    /bin/echo "Previous app preserved at ${BACKUP_APP}"
fi
/bin/mv "${STAGING_APP}" "${TARGET_APP}"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"${LSREGISTER}" -f "${TARGET_APP}"

if [ "${ENABLE_LOGIN}" = true ]; then
    "${TARGET_APP}/Contents/MacOS/wordhand" install --launch-at-login
fi

/usr/bin/open "${TARGET_APP}"
/bin/echo "Installed ${TARGET_APP}"
