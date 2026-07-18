#!/usr/bin/env bash
set -euo pipefail

root=$PWD
tmp=test/test0011.tmp
output=$tmp/output

cleanup()
{
    rm -rf "$tmp"
    rm -f test0011.out
}
trap cleanup EXIT

rm -rf "$tmp"
mkdir -p "$tmp"

cat >"$tmp/script.lua" <<'EOF_LUA'
assert(jit.version:match("^LuaJIT "))
assert(arg[0] == "script.lua")
assert(arg[1] == "-n")
assert(arg[2] == "--not-a-blud-option")
assert(arg[3] == "two words")
assert(undefined_global == nil)
print("LuaJIT runner OK")
EOF_LUA

(
    cd "$tmp"
    "$root/blud" --lua script.lua -n --not-a-blud-option "two words"
) >"$output"

grep -Fx 'LuaJIT runner OK' "$output" >/dev/null

if "$root/blud" --lua >/dev/null 2>"$tmp/error"; then
    echo "--lua without a file unexpectedly succeeded" >&2
    exit 1
fi
grep -F -- '--lua requires a Lua file' "$tmp/error" >/dev/null

touch test0011.out
