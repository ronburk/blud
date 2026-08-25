#!/usr/bin/env bash
set -euo pipefail

root=$PWD
tmp=test/test0019.tmp
output=$tmp/output
expected=$tmp/expected

cleanup()
{
    rm -rf "$tmp"
    rm -f test0019.out
}
trap cleanup EXIT

rm -rf "$tmp"
mkdir -p "$tmp"

cat >"$tmp/action-failure.bludfile" <<EOF_BLUD
all:
    shell exit 1
EOF_BLUD

if "$root/blud" -s -f "$tmp/action-failure.bludfile" all \
        >"$output" 2>&1; then
    exit 1
fi
printf 'BLUD error 256: all\n' >"$expected"
diff -u "$expected" "$output"

mkdir -p "$tmp/test-failure"
touch "$tmp/test-failure/case"

cat >"$tmp/test-failure.bludfile" <<EOF_BLUD
all: test-failure

debug :BUILD:

test-failure :TEST: case
    shell exit 1
EOF_BLUD

if (cd "$tmp" && "$root/blud" -s -f test-failure.bludfile all) \
        >"$output" 2>&1; then
    exit 1
fi
printf '[:BUILD:]:BUILD(debug)\nBLUD error 256: case\n' >"$expected"
diff -u "$expected" "$output"

touch test0019.out
