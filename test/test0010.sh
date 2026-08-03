#!/usr/bin/env bash
set -euo pipefail

runner=test/test0010.runner
log=test/test0010.log
direct_log=test/test0010-direct.log
private_log=test/test0010-private.log
public_log=test/test0010-public.log

cleanup()
{
    rm -f "$runner" "$log" "$direct_log" "$private_log" "$public_log"
    rm -f first second test0010.out
}
trap cleanup EXIT

cleanup

gcc -std=c99 -Wall -Wextra -Werror \
    -I./luajit/src \
    -o "$runner" test/test0010.c \
    ./luajit/src/libluajit.a -lm -ldl

BLUD_SCOPE_ENV=environment "$runner" test/test0010.luatest
BLUD_SCOPE_ENV=environment ./blud -B -f test/test0010.blud all target_parent >"$log"
BLUD_SCOPE_ENV=environment ./blud -B -f test/test0010.blud target_child >"$direct_log"

grep -Fx './all' "$log" >/dev/null
grep -Fx './first' "$log" >/dev/null
grep -Fx 'echo ./first ./second ' "$log" >/dev/null
grep -Fx './first ./second' "$log" >/dev/null
grep -Fx 'environment' "$log" >/dev/null
grep -Fx 'innertail' "$log" >/dev/null
grep -Fx 'echo child::outer:outer' "$log" >/dev/null
grep -Fx 'child::outer:outer' "$log" >/dev/null
grep -Fx 'echo parent:parent:parent:outer parent' "$log" >/dev/null
grep -Fx 'parent:parent:parent:outer parent' "$log" >/dev/null
grep -Fx 'echo child::outer:outer' "$direct_log" >/dev/null
grep -Fx 'child::outer:outer' "$direct_log" >/dev/null

if ./blud -f test/test0010.private.blud >"$private_log" 2>&1; then
    echo "obsolete private modifier unexpectedly succeeded" >&2
    exit 1
fi
grep -F "The 'private' target-assignment modifier is obsolete; target-specific assignments apply only to the named target." "$private_log" >/dev/null

if ./blud -f test/test0010.public.blud >"$public_log" 2>&1; then
    echo "obsolete public modifier unexpectedly succeeded" >&2
    exit 1
fi
grep -F "The 'public' target-assignment modifier is obsolete; target-specific assignments apply only to the named target." "$public_log" >/dev/null

touch test0010.out
