#!/usr/bin/env bash
set -euo pipefail

cleanup()
{
    rm -f test/test0007.runner test/test0007.source
    rm -f test/test0007.actions test/test0007.virtual
    rm -f test/test0007.first test/test0007.second
}
trap cleanup EXIT

cleanup
rm -f test0007.out

touch test/test0007.source

gcc -std=c99 -Wall -Wextra -Werror \
    -I./luajit/src \
    -o test/test0007.runner test/test0007.c \
    ./luajit/src/libluajit.a -lm -ldl

test/test0007.runner test/test0007.luatest
./blud -f test/test0007.blud all

test ! -e test/test0007.virtual
test -e test/test0007.first
test -e test/test0007.second
test "$(wc -c < test/test0007.actions)" -eq 1

touch test0007.out
