#!/usr/bin/env bash
set -euo pipefail

base_zip=/mnt/data/blud.zip
work=/mnt/data/blud
patch_file=/mnt/data/chatgpt.patch

say() {
    printf 'CLOBBER: %s\n' "$*"
}

die() {
    printf 'CLOBBER ERROR: %s\n' "$*" >&2
    exit 1
}

need_upload() {
    printf 'CLOBBER NEEDS UPLOAD: %s\n' "$1" >&2
    printf 'Please upload %s, then rerun CLOBBER.sh.\n' "$(basename "$1")" >&2
    exit 2
}

shopt -s nullglob
blud_archives=(/mnt/data/blud*.zip)
shopt -u nullglob
if ((${#blud_archives[@]} > 1)); then
    printf 'CLOBBER ERROR: duplicate blud archives found:\n' >&2
    printf '  %s\n' "${blud_archives[@]}" >&2
    rm -f -- "${blud_archives[@]}"
    printf 'CHATGPT_ACTION=RESTART_DOT_FRESH\n' >&2
    printf 'All duplicate blud archives were removed. Start the .FRESH operation over from the beginning.\n' >&2
    exit 3
fi

find /mnt/data -maxdepth 1 -type f -name '*(*).*' -delete

[ -f "$base_zip" ] || need_upload "$base_zip"

say "removing old scratch tree"
rm -rf "$work"
mkdir -p "$work"

say "unpacking $base_zip"
unzip -q "$base_zip" -d "$work"

required_files=(
    build.sh
    CHATGPT_PREFLIGHT.sh
    luajit/src/libluajit.a
    luajit/src/lua.h
    luajit/src/luaconf.h
    luajit/src/lauxlib.h
    luajit/src/lualib.h
)

for file in "${required_files[@]}"; do
    [ -f "$work/$file" ] || die "missing $work/$file after unpacking $base_zip"
done

cd "$work"

say "initializing git baseline"
git init -b main >/dev/null 2>&1 || {
    git init >/dev/null
    git checkout -B main >/dev/null
}
git config user.name "ChatGPT"
git config user.email "chatgpt@example.invalid"

rm -f "$patch_file"

git add .
git commit -m "baseline" >/dev/null

say "running build.sh"
bash build.sh

say "ready"
printf 'WORKTREE: %s\n' "$work"
printf 'HEAD: %s\n' "$(git rev-parse --short HEAD)"
