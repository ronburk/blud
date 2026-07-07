#!/usr/bin/env bash
set -e

LUAJIT_DIR="./luajit"
LUAJIT_SRC="$LUAJIT_DIR/src"
LUAJIT_LIB="$LUAJIT_SRC/libluajit.a"

if [ ! -f "$LUAJIT_LIB" ]; then
    echo "error: expected static LuaJIT library at $LUAJIT_LIB" >&2
    echo "build LuaJIT in $LUAJIT_DIR before running this script" >&2
    exit 1
fi

LUAJIT_FLAGS="-I$LUAJIT_SRC $LUAJIT_LIB -lm -ldl"
BUILD_ID=$(($(cat .build_id 2>/dev/null || echo 0) + 1))
echo $BUILD_ID > .build_id
CFLAGS="-Wall -Wextra -fmax-errors=2"
# build cstr utility
g++ -o cstr cstr.cpp $CFLAGS
./cstr runtime.lua util.lua macro.lua main.lua init.lua blud.lua builtin.blud debugger.lua implicit.lua compiler.lua compile_io.lua operator.lua scope.lua >./bludlua.c

gcc -MMD -MP -o blud blud.c bludlua.c oslinux.c $LUAJIT_FLAGS $CFLAGS -DBUILD_ID=$BUILD_ID
#gcc -MMD -MP -o blud blud.c bludlua.c oslinux.c $LUAJIT_FLAGS $CFLAGS
zip -u blud.zip *.c *.lua *.cpp *.h *.org builtin.blud build.sh gpatch.sh chatgpt_patch_start.sh chatgpt_patch_finish.sh CHATGPT_NOTES.md test.blud test/* bludfile
if command -v xclip >/dev/null; then
    echo -n "file://$(realpath ./blud.zip)" | xclip -selection clipboard -t text/uri-list
else
    echo "warning: xclip not found; clipboard not updated" >&2
fi
exit 0

g++ -o blud blud.cpp luawrap.cpp $LUAJIT_FLAGS $CFLAGS
rm ./*.luad
