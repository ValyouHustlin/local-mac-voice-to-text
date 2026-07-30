#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" && /bin/pwd)"

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

expect_exit_78 \
    "development login-item guard" \
    "${SCRIPT_DIR}/install-app.sh" --launch-at-login

expect_exit_78 \
    "unsigned release guard" \
    /usr/bin/env \
    WORDHAND_BUILD_CHANNEL=release \
    WORDHAND_CODESIGN_IDENTITY=- \
    "${SCRIPT_DIR}/build-app.sh"

/bin/echo "✓ development login-item registration is blocked"
/bin/echo "✓ unsigned release identity is blocked"
