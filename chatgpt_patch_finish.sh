#!/usr/bin/env bash
set -euo pipefail

repo=$(git rev-parse --show-toplevel)
head=$(git -C "$repo" rev-parse HEAD)
patch_dir=/mnt/data/tmp
patch=$patch_dir/chatgpt-$head.patch
mkdir -p "$patch_dir"

[ -z "$(git -C "$repo" status --porcelain --untracked-files=all)" ] || {
    echo "error: worktree is not clean" >&2
    git -C "$repo" status --short >&2
    exit 1
}

git -C "$repo" rev-parse HEAD^ >/dev/null 2>&1 || {
    echo "error: HEAD has no parent commit" >&2
    exit 1
}

rm -f "$patch_dir"/chatgpt*.patch

tmp=$(mktemp /mnt/data/.chatgpt-patch.XXXXXX)
verify=$(mktemp -d /mnt/data/chatgpt-verify.XXXXXX)
complete=false
cleanup() {
    rm -f "$tmp"
    rm -rf "$verify"
    $complete || rm -f "$patch"
}
trap cleanup EXIT

git -C "$repo" format-patch -1 --stdout HEAD > "$tmp"
[ -s "$tmp" ] || {
    echo "error: failed to create patch" >&2
    exit 1
}

patch_head=$(sed -n '1s/^From \([0-9a-f]\{40\}\) Mon Sep 17 00:00:00 2001$/\1/p' "$tmp")
[ "$patch_head" = "$head" ] || {
    echo "error: patch header does not name HEAD" >&2
    exit 1
}

mv "$tmp" "$patch"

git clone -q --no-local "$repo" "$verify/repo"
git -C "$verify/repo" checkout -q HEAD^
git -C "$verify/repo" config user.name ChatGPT
git -C "$verify/repo" config user.email chatgpt@example.invalid
git -C "$verify/repo" am --no-3way "$patch" >/dev/null

expected_tree=$(git -C "$repo" rev-parse HEAD^{tree})
actual_tree=$(git -C "$verify/repo" rev-parse HEAD^{tree})
[ "$actual_tree" = "$expected_tree" ] || {
    echo "error: applied patch does not reproduce HEAD" >&2
    exit 1
}

complete=true
printf 'PATCH: %s\n' "$patch"
grep -m1 '^Subject:' "$patch"
sha256sum "$patch"
