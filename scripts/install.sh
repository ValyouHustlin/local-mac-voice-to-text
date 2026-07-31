#!/usr/bin/env bash

set -euo pipefail

/bin/echo "Wordhand does not yet publish an authenticated public installer." >&2
/bin/echo "Build the development app from source with ./scripts/install-app.sh." >&2
/bin/echo "This retired installer performs no download, extraction, or filesystem mutation." >&2
exit 78
