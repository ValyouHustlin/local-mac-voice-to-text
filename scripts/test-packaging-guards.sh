#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" && /bin/pwd)"
GUARD_WORK_DIRECTORY="$(/usr/bin/mktemp -d /tmp/wordhand-packaging-guards.XXXXXX)"
trap '/bin/rm -rf "${GUARD_WORK_DIRECTORY}"' EXIT

expect_exit_78() {
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

expect_success() {
    local description="$1"
    shift

    if ! "$@" >/dev/null 2>&1; then
        /bin/echo "${description}: expected success" >&2
        exit 1
    fi
}

POLICY="${SCRIPT_DIR}/verify-update-identity-policy.sh"

expect_exit_78 \
    "development login-item guard" \
    "${SCRIPT_DIR}/install-app.sh" --launch-at-login

expect_exit_78 \
    "unsigned release guard" \
    /usr/bin/env \
    WORDHAND_BUILD_CHANNEL=release \
    WORDHAND_CODESIGN_IDENTITY=- \
    "${SCRIPT_DIR}/build-app.sh"

expect_success \
    "matching development update identity" \
    "${POLICY}" \
    development \
    com.valyou.wordhand.dev \
    com.valyou.wordhand.dev \
    com.valyou.wordhand.dev \
    "not set" \
    'identifier "com.valyou.wordhand.dev" and certificate root = H"stable"' \
    1 \
    com.valyou.wordhand.dev \
    com.valyou.wordhand.dev \
    "not set" \
    'identifier "com.valyou.wordhand.dev" and certificate root = H"stable"'

expect_exit_78 \
    "fresh release bypasses identity continuity" \
    "${POLICY}" \
    release \
    com.valyou.wordhand \
    com.valyou.wordhand \
    com.valyou.wordhand \
    TEAM123456 \
    'identifier "com.valyou.wordhand" and certificate leaf[subject.OU] = TEAM123456' \
    0 \
    "" \
    "" \
    "" \
    ""

expect_exit_78 \
    "wrong candidate bundle identifier" \
    "${POLICY}" \
    development \
    com.valyou.wordhand.dev \
    com.attacker.wordhand \
    com.attacker.wordhand \
    "not set" \
    'identifier "com.attacker.wordhand" and certificate root = H"stable"' \
    0 \
    "" \
    "" \
    "" \
    ""

expect_exit_78 \
    "wrong installed bundle identifier" \
    "${POLICY}" \
    development \
    com.valyou.wordhand.dev \
    com.valyou.wordhand.dev \
    com.valyou.wordhand.dev \
    "not set" \
    'identifier "com.valyou.wordhand.dev" and certificate root = H"stable"' \
    1 \
    com.valyou.wordhand \
    com.valyou.wordhand \
    "not set" \
    'identifier "com.valyou.wordhand" and certificate root = H"stable"'

expect_exit_78 \
    "changed Team ID" \
    "${POLICY}" \
    release \
    com.valyou.wordhand \
    com.valyou.wordhand \
    com.valyou.wordhand \
    TEAM654321 \
    'identifier "com.valyou.wordhand" and certificate leaf[subject.OU] = TEAM654321' \
    1 \
    com.valyou.wordhand \
    com.valyou.wordhand \
    TEAM123456 \
    'identifier "com.valyou.wordhand" and certificate leaf[subject.OU] = TEAM123456'

expect_exit_78 \
    "changed designated requirement" \
    "${POLICY}" \
    development \
    com.valyou.wordhand.dev \
    com.valyou.wordhand.dev \
    com.valyou.wordhand.dev \
    "not set" \
    'identifier "com.valyou.wordhand.dev" and certificate root = H"changed"' \
    1 \
    com.valyou.wordhand.dev \
    com.valyou.wordhand.dev \
    "not set" \
    'identifier "com.valyou.wordhand.dev" and certificate root = H"stable"'

expect_exit_78 \
    "release without Team ID" \
    "${POLICY}" \
    release \
    com.valyou.wordhand \
    com.valyou.wordhand \
    com.valyou.wordhand \
    "not set" \
    'identifier "com.valyou.wordhand" and anchor apple generic' \
    0 \
    "" \
    "" \
    "" \
    ""

expect_exit_78 \
    "wrong signed identifier" \
    "${POLICY}" \
    development \
    com.valyou.wordhand.dev \
    com.valyou.wordhand.dev \
    com.attacker.wordhand \
    "not set" \
    'identifier "com.attacker.wordhand" and certificate root = H"stable"' \
    0 \
    "" \
    "" \
    "" \
    ""

expect_exit_78 \
    "noncanonical release update path" \
    /usr/bin/env \
    WORDHAND_BUILD_CHANNEL=release \
    WORDHAND_INSTALL_DIRECTORY="${GUARD_WORK_DIRECTORY}/Release Applications" \
    "${SCRIPT_DIR}/install-app.sh"

/bin/mkdir -p "${GUARD_WORK_DIRECTORY}/Wordhand Dev.app"
/usr/bin/touch "${GUARD_WORK_DIRECTORY}/Wordhand Dev.app/installed-sentinel"
expect_exit_78 \
    "build output cannot overwrite installed target before preflight" \
    /usr/bin/env \
    WORDHAND_BUILD_CHANNEL=development \
    WORDHAND_INSTALL_DIRECTORY="${GUARD_WORK_DIRECTORY}" \
    WORDHAND_APP_OUTPUT="${GUARD_WORK_DIRECTORY}/../$(
        /usr/bin/basename "${GUARD_WORK_DIRECTORY}"
    )/Wordhand Dev.app" \
    "${SCRIPT_DIR}/install-app.sh"
if [ ! -f "${GUARD_WORK_DIRECTORY}/Wordhand Dev.app/installed-sentinel" ]; then
    /bin/echo "aliased build output mutated the installed target" >&2
    exit 1
fi

NESTED_SOURCE_APP="${GUARD_WORK_DIRECTORY}/Nested Output.app"
NESTED_INSTALL_DIRECTORY="${NESTED_SOURCE_APP}/Installed"
NESTED_TARGET_APP="${NESTED_INSTALL_DIRECTORY}/Wordhand Dev.app"
/bin/mkdir -p "${NESTED_TARGET_APP}"
/usr/bin/touch "${NESTED_TARGET_APP}/installed-sentinel"
expect_exit_78 \
    "installed target cannot be nested inside build output before preflight" \
    /usr/bin/env \
    WORDHAND_BUILD_CHANNEL=development \
    WORDHAND_INSTALL_DIRECTORY="${NESTED_INSTALL_DIRECTORY}" \
    WORDHAND_APP_OUTPUT="${NESTED_SOURCE_APP}" \
    "${SCRIPT_DIR}/install-app.sh"
if [ ! -f "${NESTED_TARGET_APP}/installed-sentinel" ]; then
    /bin/echo "nested build output mutated the installed target" >&2
    exit 1
fi

"${SCRIPT_DIR}/test-update-identity.sh"

preflight_line="$(
    /usr/bin/grep -n '"${SCRIPT_DIR}/verify-app-update.sh"' \
        "${SCRIPT_DIR}/install-app.sh" |
        /usr/bin/cut -d: -f1
)"
process_stop_line="$(
    /usr/bin/grep -n '^RUNNING_PIDS=' "${SCRIPT_DIR}/install-app.sh" |
        /usr/bin/cut -d: -f1
)"
if [ -z "${preflight_line}" ] ||
    [ -z "${process_stop_line}" ] ||
    [ "${preflight_line}" -ge "${process_stop_line}" ]; then
    /bin/echo "identity preflight must run before process termination" >&2
    exit 1
fi

/bin/echo "✓ development login-item registration is blocked"
/bin/echo "✓ unsigned release identity is blocked"
/bin/echo "✓ update identity continuity is fail-closed"
