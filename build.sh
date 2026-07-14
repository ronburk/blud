#!/usr/bin/env bash
set -e

LUAJIT_DIR="./luajit"
LUAJIT_SRC="$LUAJIT_DIR/src"
LUAJIT_LIB="$LUAJIT_SRC/libluajit.a"
LUAJIT_FILES=(
    "$LUAJIT_LIB"
    "$LUAJIT_SRC/lua.h"
    "$LUAJIT_SRC/luaconf.h"
    "$LUAJIT_SRC/lauxlib.h"
    "$LUAJIT_SRC/lualib.h"
)

for file in "${LUAJIT_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        echo "error: missing bundled LuaJIT file: $file" >&2
        exit 1
    fi
done

LUAJIT_FLAGS="-I$LUAJIT_SRC $LUAJIT_LIB -lm -ldl"
BUILD_ID=$(($(cat .build_id 2>/dev/null || echo 0) + 1))
echo $BUILD_ID > .build_id
CFLAGS="-Wall -Wextra -fmax-errors=2"
# build cstr utility
g++ -o cstr cstr.cpp $CFLAGS
./cstr runtime.lua util.lua macro.lua main.lua init.lua blud.lua builtin.blud debugger.lua implicit.lua compiler.lua compile_io.lua operator.lua scope.lua atom.lua >./bludlua.c

gcc -MMD -MP -o blud blud.c bludlua.c oslinux.c $LUAJIT_FLAGS $CFLAGS -DBUILD_ID=$BUILD_ID
#gcc -MMD -MP -o blud blud.c bludlua.c oslinux.c $LUAJIT_FLAGS $CFLAGS
zip -FS blud.zip *.c *.lua *.cpp *.h *.org builtin.blud build.sh gpatch.sh chatgpt_patch.sh chatgpt_patch_start.sh chatgpt_patch_finish.sh CHATGPT_NOTES.md CLOBBER.sh test.blud test/* bludfile .gitignore "${LUAJIT_FILES[@]}" -x bludlua.c
if command -v xclip >/dev/null; then
    echo -n "file://$(realpath ./blud.zip)" | xclip -selection clipboard -t text/uri-list
else
    echo "warning: xclip not found; clipboard not updated (no problem for ChatGPT)" >&2
fi
exit 0

g++ -o blud blud.cpp luawrap.cpp $LUAJIT_FLAGS $CFLAGS
rm ./*.luad
