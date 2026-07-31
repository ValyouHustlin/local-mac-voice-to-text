#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 0 ]; then
    /bin/echo "usage: codesign -dv --verbose=4 <app> 2>&1 | release-signature-has-runtime.sh" >&2
    exit 64
fi

/usr/bin/grep -Eq \
    '^CodeDirectory .*flags=.*[(]([^,)]*,)*runtime(,[^,)]*)*[)]'
