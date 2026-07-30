#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/wordhand-crash-recovery.XXXXXX")
writer_output="$fixture_dir/writer.out"
writer_pid=""

cleanup() {
    if [ -n "$writer_pid" ] && kill -0 "$writer_pid" 2>/dev/null; then
        kill -KILL "$writer_pid" 2>/dev/null || true
        wait "$writer_pid" 2>/dev/null || true
    fi
    rm -rf -- "$fixture_dir"
}
trap cleanup EXIT HUP INT TERM

cd "$repo_dir"
WORDHAND_SAFE=1 swift build --product wordhand >/dev/null

WORDHAND_SAFE=1 .build/debug/wordhand capture-recovery-fixture write \
    --data-directory "$fixture_dir" >"$writer_output" &
writer_pid=$!

attempt=0
while [ "$attempt" -lt 100 ]; do
    if grep -q '^samples=7 ' "$writer_output" 2>/dev/null; then
        break
    fi
    if ! kill -0 "$writer_pid" 2>/dev/null; then
        echo "fixture writer exited before acknowledging its final chunk" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep 0.05
done
grep -q '^samples=7 ' "$writer_output"

kill -KILL "$writer_pid"
wait "$writer_pid" 2>/dev/null || true
writer_pid=""

expected=$(sed -n '1p' "$writer_output")
recovered=$(WORDHAND_SAFE=1 .build/debug/wordhand \
    capture-recovery-fixture inspect --data-directory "$fixture_dir")

if [ "$recovered" != "$expected" ]; then
    echo "crash recovery mismatch" >&2
    echo "expected: $expected" >&2
    echo "recovered: $recovered" >&2
    exit 1
fi

echo "process crash recovery: exact"
echo "$recovered"
