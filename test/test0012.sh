#!/usr/bin/env bash
set -euo pipefail

root=$PWD
tmp=test/test0012.tmp
bludfile=$tmp/bludfile
output=$tmp/output
expected=$tmp/expected
marker=$tmp/ran
force=$tmp/force

cleanup()
{
    rm -rf "$tmp"
    rm -f test0012.out
}
trap cleanup EXIT

rm -rf "$tmp"
mkdir -p "$tmp"

cat >"$bludfile" <<EOF_BLUD
all: $force
    shell printf 'command-output\\n'; touch $marker
EOF_BLUD
touch "$force"

run_case()
{
    local expected_output=$1
    local should_run=$2
    shift 2

    rm -f "$output" "$expected" "$marker" "$bludfile.luac"
    stdbuf -o0 "$root/blud" "$@" -f "$bludfile" all >"$output"
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

status_bludfile=$tmp/status.bludfile
target=$tmp/target
prerequisite=$tmp/prerequisite

cat >"$status_bludfile" <<EOF_BLUD
$target: $prerequisite
    touch $target
EOF_BLUD

touch -t 202001010000 "$prerequisite"
touch -t 202001020000 "$target"

"$root/blud" -f "$status_bludfile" "$target" >"$output"
printf '%s is up to date\n' "$target" >"$expected"
cmp "$expected" "$output"

rm -f "$status_bludfile.luac"
"$root/blud" -f "$status_bludfile" >"$output"
cmp "$expected" "$output"

rm "$target"
rm -f "$status_bludfile.luac"
"$root/blud" -s -f "$status_bludfile" "$target" >"$output"
: >"$expected"
cmp "$expected" "$output"
[[ -f "$target" ]]

implicit_bludfile=$tmp/implicit.bludfile
implicit_source=$tmp/implicit.in
implicit_target=$tmp/implicit.out

cat >"$implicit_bludfile" <<EOF_BLUD
$tmp/%.out: $tmp/%.in
    touch $implicit_target
EOF_BLUD

touch -t 202001010000 "$implicit_source"
touch -t 202001020000 "$implicit_target"

"$root/blud" -f "$implicit_bludfile" "$implicit_target" >"$output"
printf '%s is up to date\n' "$implicit_target" >"$expected"
cmp "$expected" "$output"

ruleless=$tmp/ruleless
touch "$ruleless"

rm -f "$status_bludfile.luac"
"$root/blud" -f "$status_bludfile" "$ruleless" >"$output"
printf '%s is up to date\n' "$ruleless" >"$expected"
cmp "$expected" "$output"

source_list_bludfile=$tmp/source-list.bludfile
source=$tmp/source.c
object=$tmp/source.o
program=$tmp/program

cat >"$source_list_bludfile" <<EOF_BLUD
$tmp/%.o: $tmp/%.c
    touch $object

$program :: $source
    touch $program
EOF_BLUD

touch -t 202001010000 "$source"
touch -t 202001020000 "$object"
touch -t 202001030000 "$program"

"$root/blud" -f "$source_list_bludfile" "$program" >"$output"
printf '%s is up to date\n' "$program" >"$expected"
cmp "$expected" "$output"

touch test0012.out
