#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" && /bin/pwd)"
WORK_DIRECTORY="$(/usr/bin/mktemp -d /tmp/wordhand-update-identity.XXXXXX)"
trap '/bin/rm -rf "${WORK_DIRECTORY}"' EXIT

make_app() {
    local app_path="$1"
    local identifier="$2"
    local executable="$3"
    /bin/mkdir -p "${app_path}/Contents/MacOS"
    /bin/cp "${executable}" "${app_path}/Contents/MacOS/wordhand"
    /usr/bin/plutil -create xml1 "${app_path}/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleIdentifier -string "${identifier}" \
        "${app_path}/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleExecutable -string wordhand \
        "${app_path}/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundlePackageType -string APPL \
        "${app_path}/Contents/Info.plist"
    /usr/bin/codesign --force --deep --sign - "${app_path}" >/dev/null 2>&1
}

expect_rejection() {
    local description="$1"
    shift
    set +e
    "$@" >/dev/null 2>&1
    local status=$?
    set -e
    if [ "${status}" -ne 78 ]; then
        /bin/echo "${description}: expected exit 78, observed ${status}" >&2
        exit 1
    fi
}

INSTALLED_APP="${WORK_DIRECTORY}/Installed.app"
MATCHING_APP="${WORK_DIRECTORY}/Matching.app"
WRONG_ID_APP="${WORK_DIRECTORY}/Wrong ID.app"
WRONG_SIGNED_ID_APP="${WORK_DIRECTORY}/Wrong Signed ID.app"
CHANGED_REQUIREMENT_APP="${WORK_DIRECTORY}/Changed Requirement.app"
CORRUPT_APP="${WORK_DIRECTORY}/Corrupt.app"
CORRUPT_INSTALLED_APP="${WORK_DIRECTORY}/Corrupt Installed.app"
SYMLINK_INSTALLED_APP="${WORK_DIRECTORY}/Installed Symlink.app"
MISSING_INSTALLED_APP="${WORK_DIRECTORY}/Missing.app"
SENTINEL="${WORK_DIRECTORY}/installed-sentinel"

make_app \
    "${INSTALLED_APP}" \
    com.valyou.wordhand.dev \
    /usr/bin/true
/usr/bin/ditto "${INSTALLED_APP}" "${MATCHING_APP}"
make_app \
    "${WRONG_ID_APP}" \
    com.attacker.wordhand \
    /usr/bin/true
/usr/bin/ditto "${INSTALLED_APP}" "${WRONG_SIGNED_ID_APP}"
/usr/bin/codesign \
    --force \
    --deep \
    --identifier com.attacker.wordhand \
    --sign - \
    "${WRONG_SIGNED_ID_APP}" >/dev/null 2>&1
make_app \
    "${CHANGED_REQUIREMENT_APP}" \
    com.valyou.wordhand.dev \
    /usr/bin/false
/usr/bin/ditto "${INSTALLED_APP}" "${CORRUPT_APP}"
/usr/bin/plutil -insert CFBundleVersion -string 2 \
    "${CORRUPT_APP}/Contents/Info.plist"
/usr/bin/ditto "${INSTALLED_APP}" "${CORRUPT_INSTALLED_APP}"
/usr/bin/plutil -insert CFBundleVersion -string 2 \
    "${CORRUPT_INSTALLED_APP}/Contents/Info.plist"
/bin/ln -s "${INSTALLED_APP}" "${SYMLINK_INSTALLED_APP}"
/usr/bin/touch "${SENTINEL}"

"${SCRIPT_DIR}/verify-app-update.sh" \
    development \
    "${MATCHING_APP}" \
    "${INSTALLED_APP}" >/dev/null
"${SCRIPT_DIR}/verify-app-update.sh" \
    development \
    "${MATCHING_APP}" \
    "${MISSING_INSTALLED_APP}" >/dev/null

expect_rejection \
    "validly signed wrong bundle identifier" \
    "${SCRIPT_DIR}/verify-app-update.sh" \
    development \
    "${WRONG_ID_APP}" \
    "${INSTALLED_APP}"
expect_rejection \
    "validly signed wrong signed identifier" \
    "${SCRIPT_DIR}/verify-app-update.sh" \
    development \
    "${WRONG_SIGNED_ID_APP}" \
    "${INSTALLED_APP}"
expect_rejection \
    "validly signed changed designated requirement" \
    "${SCRIPT_DIR}/verify-app-update.sh" \
    development \
    "${CHANGED_REQUIREMENT_APP}" \
    "${INSTALLED_APP}"
expect_rejection \
    "corrupt candidate signature" \
    "${SCRIPT_DIR}/verify-app-update.sh" \
    development \
    "${CORRUPT_APP}" \
    "${INSTALLED_APP}"
expect_rejection \
    "corrupt installed signature" \
    "${SCRIPT_DIR}/verify-app-update.sh" \
    development \
    "${MATCHING_APP}" \
    "${CORRUPT_INSTALLED_APP}"
expect_rejection \
    "symlinked installed target" \
    "${SCRIPT_DIR}/verify-app-update.sh" \
    development \
    "${MATCHING_APP}" \
    "${SYMLINK_INSTALLED_APP}"

if [ ! -f "${SENTINEL}" ] ||
    [ ! -d "${INSTALLED_APP}" ] ||
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "${INSTALLED_APP}/Contents/Info.plist")" != "com.valyou.wordhand.dev" ]; then
    /bin/echo "identity rejection mutated the installed fixture" >&2
    exit 1
fi

/bin/echo "✓ signed update identity fixtures accept only the exact identity"
