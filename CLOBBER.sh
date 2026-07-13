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

[ -e "$base_zip" ] || need_upload "$base_zip"
[ -L "$base_zip" ] || die "$base_zip is not a symbolic link"

link_target=$(readlink -- "$base_zip") ||
    die "cannot read symbolic link $base_zip"

if [[ ! "$link_target" =~ ^blud-upload-[0-9]{8}T[0-9]{6}\.[0-9]{9}Z\.zip$ ]]; then
    die "$base_zip points to invalid archive name: $link_target"
fi

archive_target=/mnt/data/$link_target
[ -f "$archive_target" ] || die "archive target does not exist: $archive_target"
[ ! -L "$archive_target" ] || die "archive target is itself a symbolic link: $archive_target"
[ -r "$archive_target" ] || die "archive target is not readable: $archive_target"

shopt -s nullglob
collision_archives=(/mnt/data/blud\([0-9]*\).zip)
shopt -u nullglob
if ((${#collision_archives[@]} > 0)); then
    say "removing stale collision-renamed blud archives"
    rm -f -- "${collision_archives[@]}"
fi

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
