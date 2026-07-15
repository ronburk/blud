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
    BLUD_SHELL_TEST='verbatim  value' PATH=/nonexistent \
        ./blud -B -f "$bludfile" all
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

# Unsupported syntax is an error; it must not trigger an implicit shell.
cat >"$bludfile" <<EOF_BLUD
all:
    echo blocked >$tmp/implicit
EOF_BLUD
if run_internal >/dev/null 2>&1; then
    echo "unsupported syntax unexpectedly succeeded" >&2
    exit 1
fi
[[ ! -e "$tmp/implicit" ]]

# An unknown command is also an error unless explicitly prefixed by `shell`.
cat >"$bludfile" <<'EOF_BLUD'
all:
    printf blocked
EOF_BLUD
if run_internal >/dev/null 2>&1; then
    echo "unknown command unexpectedly succeeded" >&2
    exit 1
fi

# `shell` passes its remainder unchanged, including substitution and redirection.
cat >"$bludfile" <<'EOF_BLUD'
all:
    shell printf '%s' "$BLUD_SHELL_TEST" >test/test0008.tmp/explicit
EOF_BLUD
run_internal
[[ $(<"$tmp/explicit") == 'verbatim  value' ]]

# Recursive rm removes the remaining directory tree.
cat >"$bludfile" <<EOF_BLUD
all:
    rm -r $tmp/a
EOF_BLUD
run_internal
[[ ! -e "$tmp/a" ]]

touch test0008.out
