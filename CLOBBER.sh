#!/usr/bin/env bash
set -euo pipefail

base_zip=/mnt/data/blud.zip
work=/mnt/data/blud
tmp=/mnt/data/blud_unpack.$$
luajit_src=/mnt/data/LuaJIT-2.1

say() {
    printf 'CLOBBER: %s\n' "$*"
}

die() {
    printf 'CLOBBER ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    rm -rf "$tmp"
}
trap cleanup EXIT

# Safety: this script is intentionally specific to ChatGPT's sandbox.
[ "$work" = "/mnt/data/blud" ] || die "internal work path changed: $work"
[ -f "$base_zip" ] || die "missing $base_zip"

say "removing old scratch tree"
rm -rf "$work"
rm -rf "$tmp"
mkdir -p "$work" "$tmp"

say "unpacking $base_zip"
unzip -q "$base_zip" -d "$tmp"

mapfile -t build_files < <(find "$tmp" -maxdepth 2 -type f -name build.sh | sort)
if [ "${#build_files[@]}" -ne 1 ]; then
    printf 'CLOBBER ERROR: expected exactly one build.sh in unpacked zip, found %s\n' "${#build_files[@]}" >&2
    printf '%s\n' "${build_files[@]}" >&2
    exit 1
fi

src_dir=$(dirname "${build_files[0]}")
say "source root: $src_dir"

shopt -s dotglob nullglob
mv "$src_dir"/* "$work"/
shopt -u dotglob nullglob

cd "$work"

say "setting up LuaJIT symlink if available"
if [ -L luajit ] && [ ! -e luajit ]; then
    rm -f luajit
fi
if [ ! -e luajit ] && [ -d "$luajit_src" ]; then
    ln -s "$luajit_src" luajit
fi

say "initializing git baseline"
git init -b main >/dev/null 2>&1 || {
    git init >/dev/null
    git checkout -B main >/dev/null
}
git config user.name "ChatGPT"
git config user.email "chatgpt@example.invalid"

rm -f /mnt/data/chatgpt.patch

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
