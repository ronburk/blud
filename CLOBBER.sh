#!/usr/bin/env bash
set -euo pipefail

work=/mnt/data/blud
patch_file=/mnt/data/chatgpt.patch

say() {
    printf 'CLOBBER: %s\n' "$*"
}

die() {
    printf 'CLOBBER ERROR: %s\n' "$*" >&2
    exit 1
}

shopt -s nullglob
archives=(/mnt/data/blud-upload-*.zip)
shopt -u nullglob

((${#archives[@]} > 0)) || die "no blud-upload-*.zip archive found"

archive=$(
    printf '%s\n' "${archives[@]}" |
        LC_ALL=C sort -t- -k3 -n |
        tail -n1
)
archive_name=${archive##*/}

if [[ ! "$archive_name" =~ ^blud-upload-([0-9]+)\.zip$ ]]; then
    die "invalid archive name: $archive_name"
fi

archive_timestamp=${BASH_REMATCH[1]}

[ -f "$archive" ] || die "archive is not a regular file: $archive"
[ ! -L "$archive" ] || die "archive is a symbolic link: $archive"
[ -r "$archive" ] || die "archive is not readable: $archive"

archive_mtime=$(stat -c %Y -- "$archive")
[ "$archive_mtime" -le "$archive_timestamp" ] ||
    die "archive mtime is newer than its embedded timestamp: $archive"

unzip -tq "$archive" >/dev/null ||
    die "archive integrity check failed: $archive"

say "removing old scratch tree"
rm -rf "$work"
mkdir -p "$work"

say "unpacking $archive"
unzip -q "$archive" -d "$work"

required_files=(
    build.sh
    luajit/src/libluajit.a
    luajit/src/lua.h
    luajit/src/luaconf.h
    luajit/src/lauxlib.h
    luajit/src/lualib.h
)

for file in "${required_files[@]}"; do
    [ -f "$work/$file" ] || die "missing $work/$file after unpacking $archive"
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
