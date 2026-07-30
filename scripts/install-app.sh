#!/usr/bin/env bash
# Install the locally built app in the standard Applications directory when writable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" && /bin/pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && /bin/pwd)"
SOURCE_APP="${WORDHAND_APP_OUTPUT:-${REPO_DIR}/dist/Wordhand.app}"
DEFAULT_INSTALL_DIRECTORY="/Applications"
if [ ! -w "${DEFAULT_INSTALL_DIRECTORY}" ]; then
    DEFAULT_INSTALL_DIRECTORY="${HOME}/Applications"
fi
INSTALL_DIRECTORY="${WORDHAND_INSTALL_DIRECTORY:-${DEFAULT_INSTALL_DIRECTORY}}"
TARGET_APP="${INSTALL_DIRECTORY}/Wordhand.app"
BACKUP_DIRECTORY="${WORDHAND_BACKUP_DIRECTORY:-${HOME}/Library/Application Support/Wordhand/App Backups}"
LEGACY_INSTALL_DIRECTORY="${HOME}/Applications"
LEGACY_TARGET_APP="${LEGACY_INSTALL_DIRECTORY}/Wordhand.app"
ENABLE_LOGIN=false
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

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

if [ "${ENABLE_LOGIN}" = true ]; then
    for previous_app in "${TARGET_APP}" "${LEGACY_TARGET_APP}"; do
        previous_binary="${previous_app}/Contents/MacOS/wordhand"
        if [ -x "${previous_binary}" ]; then
            "${previous_binary}" install --uninstall >/dev/null 2>&1 || true
            break
        fi
    done
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

STAGING_APP="${INSTALL_DIRECTORY}/.Wordhand.app.staging.$$"
trap '/bin/rm -rf "${STAGING_APP}"' EXIT
/usr/bin/ditto "${SOURCE_APP}" "${STAGING_APP}"
/usr/bin/codesign --verify --deep --strict "${STAGING_APP}"

archive_app() {
    local app_path="$1"
    local label="$2"
    local timestamp
    local backup_app
    timestamp="$(/bin/date +%Y%m%d-%H%M%S)"
    backup_app="${BACKUP_DIRECTORY}/Wordhand.${label}.${timestamp}.$$.app-backup"
    "${LSREGISTER}" -u "${app_path}" >/dev/null 2>&1 || true
    /bin/mv "${app_path}" "${backup_app}"
    /bin/echo "Previous app preserved at ${backup_app}"
}

if [ -e "${TARGET_APP}" ]; then
    archive_app "${TARGET_APP}" "backup"
fi

if [ "${LEGACY_TARGET_APP}" != "${TARGET_APP}" ] && [ -e "${LEGACY_TARGET_APP}" ]; then
    archive_app "${LEGACY_TARGET_APP}" "legacy"
fi
/bin/mv "${STAGING_APP}" "${TARGET_APP}"

for legacy_backup in "${LEGACY_INSTALL_DIRECTORY}"/Wordhand.backup.*.app; do
    [ -e "${legacy_backup}" ] || continue
    "${LSREGISTER}" -u "${legacy_backup}" >/dev/null 2>&1 || true
    legacy_name="$(/usr/bin/basename "${legacy_backup}" .app)"
    /bin/mv "${legacy_backup}" "${BACKUP_DIRECTORY}/${legacy_name}.app-backup"
done

"${LSREGISTER}" -f "${TARGET_APP}"
if [ "${SOURCE_APP}" != "${TARGET_APP}" ]; then
    "${LSREGISTER}" -u "${SOURCE_APP}" >/dev/null 2>&1 || true
fi
/usr/bin/mdimport -i "${TARGET_APP}" >/dev/null 2>&1 || true

if [ "${ENABLE_LOGIN}" = true ]; then
    "${TARGET_APP}/Contents/MacOS/wordhand" install --launch-at-login
fi

/usr/bin/open "${TARGET_APP}"
if [ "${SOURCE_APP}" != "${TARGET_APP}" ]; then
    "${LSREGISTER}" -u "${SOURCE_APP}" >/dev/null 2>&1 || true
fi
/bin/echo "Installed ${TARGET_APP}"
