#!/usr/bin/env bash
set -euo pipefail

# Each generated bludfile contains one focused action. PATH is disabled for
# internal-command cases, proving no external utility supplied the behavior.
tmp=test/test0008.tmp
bludfile=$tmp/bludfile

# Remove all temporary files even when an assertion aborts the test.
cleanup()
{
    rm -rf "$tmp"
}
trap cleanup EXIT

rm -rf "$tmp"
mkdir -p "$tmp"

# Run the generated action with no executable search path. Only built-ins and
# blud's own already-running process remain available.
run_internal()
{
    PATH=/nonexistent ./blud -B -f "$bludfile" all
}

# Exercise mkdir -p, touch, relative glob expansion, and rm.
cat >"$bludfile" <<EOF_BLUD
all:
    mkdir -p $tmp/a/b
EOF_BLUD
run_internal
[[ -d "$tmp/a/b" ]]

cat >"$bludfile" <<EOF_BLUD
all:
    touch $tmp/a/b/one $tmp/a/b/two
EOF_BLUD
run_internal
[[ -f "$tmp/a/b/one" ]]
[[ -f "$tmp/a/b/two" ]]

cat >"$bludfile" <<EOF_BLUD
all:
    rm $tmp/a/b/t*
EOF_BLUD
run_internal
[[ -f "$tmp/a/b/one" ]]
[[ ! -e "$tmp/a/b/two" ]]

# Absolute patterns must preserve their root while globbing.
absolute_tmp=$PWD/$tmp
cat >"$bludfile" <<EOF_BLUD
all:
    touch $absolute_tmp/absolute-one $absolute_tmp/absolute-two
EOF_BLUD
run_internal

cat >"$bludfile" <<EOF_BLUD
all:
    rm $absolute_tmp/absolute-*
EOF_BLUD
run_internal
[[ ! -e "$tmp/absolute-one" ]]
[[ ! -e "$tmp/absolute-two" ]]

# Quoting and echo must be interpreted internally.
cat >"$bludfile" <<'EOF_BLUD'
all:
    echo "internal echo"
EOF_BLUD
output=$(run_internal)
[[ "$output" == *$'\ninternal echo' ]]

# cd changes the process directory and therefore affects a later action.
cat >"$bludfile" <<EOF_BLUD
all: after
after: enter
    touch cd-result
enter:
    cd $tmp
EOF_BLUD
run_internal
[[ -f "$tmp/cd-result" ]]

# Redirection is unsupported internally and must reach the platform shell.
cat >"$bludfile" <<EOF_BLUD
all:
    printf fallback >$tmp/fallback
EOF_BLUD
./blud -B -f "$bludfile" all
[[ $(<"$tmp/fallback") == fallback ]]

# Recursive rm removes the remaining directory tree.
cat >"$bludfile" <<EOF_BLUD
all:
    rm -r $tmp/a
EOF_BLUD
run_internal
[[ ! -e "$tmp/a" ]]

touch test0008.out
