#!/usr/bin/env bash
set -euo pipefail

tmp=test/test0009.tmp
runner=test/test0009.runner
bludfile=$tmp/bludfile
log=$tmp/error.log

cleanup()
{
    rm -rf "$tmp"
    rm -f "$runner"
}
trap cleanup EXIT

rm -rf "$tmp"
rm -f "$runner" test0009.out
mkdir -p "$tmp/entries"
ln -s missing "$tmp/entries/dangling"
touch "$tmp/entries/real"

gcc -std=gnu99 -Wall -Wextra -Werror \
    -o "$runner" test/test0009.c oslinux.c
"$runner" "$tmp/entries"

cat >"$bludfile" <<EOF_BLUD
all:
    rm $tmp/missing/*
EOF_BLUD

if ./blud -B -f "$bludfile" all >"$log" 2>&1; then
    echo "missing directory unexpectedly enumerated successfully" >&2
    exit 1
fi
grep -F "could not enumerate directory: $tmp/missing" "$log" >/dev/null

touch test0009.out
