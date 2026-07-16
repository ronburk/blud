#!/usr/bin/env bash
set -euo pipefail

runner=test/test0010.runner
log=test/test0010.log

cleanup()
{
    rm -f "$runner" "$log"
    rm -f first second test0010.out
}
trap cleanup EXIT

cleanup

gcc -std=c99 -Wall -Wextra -Werror \
    -I./luajit/src \
    -o "$runner" test/test0010.c \
    ./luajit/src/libluajit.a -lm -ldl

BLUD_SCOPE_ENV=environment "$runner" test/test0010.luatest
BLUD_SCOPE_ENV=environment ./blud -B -f test/test0010.blud all >"$log"

grep -Fx './all' "$log" >/dev/null
grep -Fx './first' "$log" >/dev/null
grep -Fx 'echo ./first ./second ' "$log" >/dev/null
grep -Fx './first ./second' "$log" >/dev/null
grep -Fx 'environment' "$log" >/dev/null
grep -Fx 'innertail' "$log" >/dev/null

touch test0010.out
