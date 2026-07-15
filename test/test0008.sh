#!/usr/bin/env bash
set -euo pipefail

tmp=test/test0008.tmp
bludfile=$tmp/bludfile

cleanup()
{
    rm -rf "$tmp"
}
trap cleanup EXIT

rm -rf "$tmp"
mkdir -p "$tmp"

run_internal()
{
    PATH=/nonexistent ./blud -B -f "$bludfile" all
}

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

cat >"$bludfile" <<'EOF_BLUD'
all:
    echo "internal echo"
EOF_BLUD
output=$(run_internal)
[[ "$output" == *$'\ninternal echo' ]]

cat >"$bludfile" <<EOF_BLUD
all: after
after: enter
    touch cd-result
enter:
    cd $tmp
EOF_BLUD
run_internal
[[ -f "$tmp/cd-result" ]]

cat >"$bludfile" <<EOF_BLUD
all:
    printf fallback >$tmp/fallback
EOF_BLUD
./blud -B -f "$bludfile" all
[[ $(<"$tmp/fallback") == fallback ]]

cat >"$bludfile" <<EOF_BLUD
all:
    rm -r $tmp/a
EOF_BLUD
run_internal
[[ ! -e "$tmp/a" ]]

touch test0008.out
