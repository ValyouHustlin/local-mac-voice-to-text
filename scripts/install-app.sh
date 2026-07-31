#!/usr/bin/env bash
# Install the locally built app in the standard Applications directory when writable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" && /bin/pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && /bin/pwd)"
BUILD_CHANNEL="${WORDHAND_BUILD_CHANNEL:-development}"
DEFAULT_INSTALL_DIRECTORY="/Applications"
if [ ! -w "${DEFAULT_INSTALL_DIRECTORY}" ]; then
    DEFAULT_INSTALL_DIRECTORY="${HOME}/Applications"
fi
INSTALL_DIRECTORY="${WORDHAND_INSTALL_DIRECTORY:-${DEFAULT_INSTALL_DIRECTORY}}"
BACKUP_DIRECTORY="${WORDHAND_BACKUP_DIRECTORY:-${HOME}/Library/Application Support/Wordhand/App Backups}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

case "${BUILD_CHANNEL}" in
    development)
        APP_NAME="Wordhand Dev"
        ;;
    release)
        APP_NAME="Wordhand"
        ;;
    *)
        /bin/echo "WORDHAND_BUILD_CHANNEL must be development or release" >&2
        exit 64
        ;;
esac

if [ "$#" -ne 0 ]; then
    if [ "$1" = "--launch-at-login" ]; then
        /bin/echo "installers never register a login item during updates" >&2
        /bin/echo "signed releases expose launch at login in Wordhand Settings" >&2
        exit 78
    fi
    /bin/echo "unknown option: $1" >&2
    /bin/echo "usage: scripts/install-app.sh" >&2
    exit 64
fi

SOURCE_APP="${WORDHAND_APP_OUTPUT:-${REPO_DIR}/dist/${APP_NAME}.app}"
TARGET_APP="${INSTALL_DIRECTORY}/${APP_NAME}.app"
TARGET_BINARY="${TARGET_APP}/Contents/MacOS/wordhand"

canonical_destination() {
    local path="$1"
    local parent
    local name
    if [ -e "${path}" ] || [ -L "${path}" ]; then
        /bin/realpath "${path}"
        return
    fi
    parent="$(
        cd "$(/usr/bin/dirname "${path}")" &&
            /bin/pwd -P
    )"
    name="$(/usr/bin/basename "${path}")"
    /bin/echo "${parent}/${name}"
}

if [ ! -d "$(/usr/bin/dirname "${SOURCE_APP}")" ]; then
    /bin/echo "build output parent directory does not exist" >&2
    exit 78
fi
/bin/mkdir -p "${INSTALL_DIRECTORY}"
SOURCE_APP_CANONICAL="$(canonical_destination "${SOURCE_APP}")"
TARGET_APP_CANONICAL="$(canonical_destination "${TARGET_APP}")"
case "${SOURCE_APP_CANONICAL}" in
    "${TARGET_APP_CANONICAL}"|"${TARGET_APP_CANONICAL}/"*)
        /bin/echo "build output must be separate from the installed app" >&2
        exit 78
        ;;
esac
case "${TARGET_APP_CANONICAL}" in
    "${SOURCE_APP_CANONICAL}/"*)
        /bin/echo "installed app must be separate from the build output" >&2
        exit 78
        ;;
esac
if [ "${BUILD_CHANNEL}" = "release" ] &&
    [ "${TARGET_APP_CANONICAL}" != "/Applications/Wordhand.app" ]; then
    /bin/echo "release updates require the canonical /Applications/Wordhand.app path" >&2
    exit 78
fi

"${SCRIPT_DIR}/build-app.sh"

STAGING_APP="${INSTALL_DIRECTORY}/.Wordhand.app.staging.$$"
trap '/bin/rm -rf "${STAGING_APP}"' EXIT
/usr/bin/ditto "${SOURCE_APP}" "${STAGING_APP}"
"${SCRIPT_DIR}/verify-app-update.sh" \
    "${BUILD_CHANNEL}" \
    "${STAGING_APP}" \
    "${TARGET_APP}"

RUNNING_PIDS="$(/usr/bin/pgrep -f "^${TARGET_BINARY}( |$)" || true)"
if [ -n "${RUNNING_PIDS}" ]; then
    /bin/echo "Stopping the current Wordhand process for a clean update…"
    while IFS= read -r process_id; do
        [ -n "${process_id}" ] || continue
        /bin/kill -TERM "${process_id}"
    done <<< "${RUNNING_PIDS}"
    for _ in 1 2 3 4 5; do
        if ! /usr/bin/pgrep -f "^${TARGET_BINARY}( |$)" >/dev/null 2>&1; then
            break
        fi
        /bin/sleep 1
    done
    if /usr/bin/pgrep -f "^${TARGET_BINARY}( |$)" >/dev/null 2>&1; then
        /bin/echo "Wordhand did not stop cleanly; installation aborted." >&2
        exit 1
    fi
fi

/bin/mkdir -p "${INSTALL_DIRECTORY}" "${BACKUP_DIRECTORY}"
/bin/chmod 700 "${BACKUP_DIRECTORY}"

# Older installers kept rollback bundles with an `.app` suffix. Even outside
# Applications, LaunchServices can retain those as duplicate Wordhand apps.
# Preserve every rollback while making it unambiguously non-launchable and
# non-indexable until a user deliberately renames it back.
for archived_app in "${BACKUP_DIRECTORY}"/*.app; do
    [ -e "${archived_app}" ] || continue
    "${LSREGISTER}" -u "${archived_app}" >/dev/null 2>&1 || true
    /bin/mv "${archived_app}" "${archived_app%.app}.app-backup"
done

archive_app() {
    local app_path="$1"
    local label="$2"
    local timestamp
    local backup_app
    timestamp="$(/bin/date +%Y%m%d-%H%M%S)"
    backup_app="${BACKUP_DIRECTORY}/${APP_NAME}.${label}.${timestamp}.$$.app-backup"
    "${LSREGISTER}" -u "${app_path}" >/dev/null 2>&1 || true
    /bin/mv "${app_path}" "${backup_app}"
    /bin/echo "Previous app preserved at ${backup_app}"
}

if [ -e "${TARGET_APP}" ]; then
    archive_app "${TARGET_APP}" "backup"
fi
/bin/mv "${STAGING_APP}" "${TARGET_APP}"

"${LSREGISTER}" -f "${TARGET_APP}"
if [ "${SOURCE_APP}" != "${TARGET_APP}" ]; then
    "${LSREGISTER}" -u "${SOURCE_APP}" >/dev/null 2>&1 || true
fi
/usr/bin/mdimport -i "${TARGET_APP}" >/dev/null 2>&1 || true

/usr/bin/open "${TARGET_APP}"
if [ "${SOURCE_APP}" != "${TARGET_APP}" ]; then
    "${LSREGISTER}" -u "${SOURCE_APP}" >/dev/null 2>&1 || true
fi
/bin/echo "Installed ${TARGET_APP}"
