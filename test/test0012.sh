#!/usr/bin/env bash
set -euo pipefail

root=$PWD
tmp=test/test0012.tmp
bludfile=$tmp/bludfile
output=$tmp/output
expected=$tmp/expected
marker=$tmp/ran

cleanup()
{
    rm -rf "$tmp"
    rm -f test0012.out
}
trap cleanup EXIT

rm -rf "$tmp"
mkdir -p "$tmp"

cat >"$bludfile" <<EOF_BLUD
all:
    shell printf 'command-output\\n'; touch $marker
EOF_BLUD

run_case()
{
    local expected_output=$1
    local should_run=$2
    shift 2

    rm -f "$output" "$expected" "$marker"
    "$root/blud" "$@" -f "$bludfile" all >"$output"
    printf '%s' "$expected_output" >"$expected"
    cmp "$expected" "$output"

    if [[ "$should_run" == true ]]; then
        [[ -f "$marker" ]]
    else
        [[ ! -e "$marker" ]]
    fi
}

action="shell printf 'command-output\\n'; touch $marker"
run_case "$action"$'\ncommand-output\n' true
run_case $'command-output\n' true -s
run_case $'command-output\n' true --silent
run_case $'command-output\n' true --quiet
run_case "$action"$'\n' false -n
run_case "$action"$'\n' false -n -s
run_case "$action"$'\n' false -s -n

touch test0012.out
