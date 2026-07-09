#!/usr/bin/env bash
set -euo pipefail

base_zip=/mnt/data/blud.zip
luajit_zip=/mnt/data/luajit.zip
work=/mnt/data/blud
luajit_dir=$work/luajit
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

[ -f "$base_zip" ] || need_upload "$base_zip"
[ -f "$luajit_zip" ] || need_upload "$luajit_zip"

say "removing old scratch tree"
rm -rf "$work"
mkdir -p "$work"

say "unpacking $base_zip"
unzip -q "$base_zip" -d "$work"
[ -f "$work/build.sh" ] || die "missing $work/build.sh after unpacking $base_zip"

if [ ! -d "$luajit_dir" ]; then
    say "creating LuaJIT tree from $luajit_zip"
    mkdir -p "$luajit_dir"
    unzip -q "$luajit_zip" -d "$luajit_dir"
fi

if [ ! -f "$luajit_dir/Makefile" ]; then
    mapfile -t makefiles < <(find "$luajit_dir" -mindepth 2 -maxdepth 2 -type f -name Makefile | sort)
    if [ "${#makefiles[@]}" -eq 1 ]; then
        nested_dir=$(dirname "${makefiles[0]}")
        say "flattening LuaJIT source root from $nested_dir"
        shopt -s dotglob nullglob
        mv "$nested_dir"/* "$luajit_dir"/
        shopt -u dotglob nullglob
        rmdir "$nested_dir"
    fi
fi

[ -f "$luajit_dir/Makefile" ] || die "missing $luajit_dir/Makefile after unpacking $luajit_zip"

say "building LuaJIT"
make -C "$luajit_dir"

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

status=$(git status --porcelain)
if [ -n "$status" ]; then
    printf 'CLOBBER ERROR: worktree dirty after build.sh\n' >&2
    printf '%s\n' "$status" >&2
    exit 1
fi

say "ready"
printf 'WORKTREE: %s\n' "$work"
printf 'HEAD: %s\n' "$(git rev-parse --short HEAD)"
printf 'STATUS: clean\n'
