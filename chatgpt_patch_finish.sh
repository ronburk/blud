#!/usr/bin/env bash
set -euo pipefail

work=${CHATGPT_WORK:-/mnt/data/blud}
patch=${CHATGPT_PATCH:-/mnt/data/chatgpt.patch}
patch_tmp=${CHATGPT_PATCH_TMP:-/mnt/data/chatgpt.patch.tmp}
state=${CHATGPT_STATE:-/mnt/data/chatgpt_patch.state}
expected=${CHATGPT_EXPECTED:-/mnt/data/chatgpt_patch.expected}
actual=${CHATGPT_ACTUAL:-/mnt/data/chatgpt_patch.actual}
expected_sorted=${CHATGPT_EXPECTED_SORTED:-/mnt/data/chatgpt_patch.expected.sorted}
actual_patch_files=${CHATGPT_ACTUAL_PATCH_FILES:-/mnt/data/chatgpt_patch.files.actual}

add_local_ignores() {
    mkdir -p .git/info
    touch .git/info/exclude
    grep -qxF '/luajit' .git/info/exclude || printf '/luajit\n' >> .git/info/exclude
}

ensure_luajit_link() {
    add_local_ignores
    if [ ! -e luajit ] && [ -d /mnt/data/LuaJIT-2.1 ]; then
        ln -s /mnt/data/LuaJIT-2.1 luajit
    fi
}

rm -f "$patch" "$patch_tmp" "$actual" "$expected_sorted" "$actual_patch_files"

[ -f "$state" ] || {
    echo "error: missing $state; run chatgpt_patch_start.sh first" >&2
    exit 1
}

[ -f "$expected" ] || {
    echo "error: missing $expected; run chatgpt_patch_start.sh first" >&2
    exit 1
}

subject=$(sed -n '1p' "$state")
baseline=$(sed -n '2p' "$state")
mode=$(sed -n '3p' "$state")

cd "$work"

[ -d .git ] || {
    echo "error: $work is not a git repo" >&2
    exit 1
}

[ "$(git rev-parse HEAD)" = "$baseline" ] || {
    echo "error: HEAD is not the baseline recorded by chatgpt_patch_start.sh" >&2
    echo "recorded: $baseline" >&2
    echo "current:  $(git rev-parse HEAD)" >&2
    exit 1
}

ensure_luajit_link

bash build.sh

git checkout -- bludlua.c 2>/dev/null || true
rm -f .build_id blud blud.d bludlua.d cstr blud.zip

{
    git diff --name-only
    git ls-files --others --exclude-standard
} | sort -u > "$actual"
sort "$expected" > "$expected_sorted"

if ! cmp -s "$actual" "$expected_sorted"; then
    echo "error: changed files do not match expected files" >&2
    echo "expected:" >&2
    sed 's/^/    /' "$expected_sorted" >&2
    echo "actual:" >&2
    sed 's/^/    /' "$actual" >&2
    exit 1
fi

while IFS= read -r file; do
    git add -- "$file"
done < "$expected_sorted"

git commit -q -m "$subject"
git format-patch --stdout HEAD~1 > "$patch_tmp"

[ -s "$patch_tmp" ] || {
    echo "error: failed to create patch" >&2
    exit 1
}

grep -qxF "Subject: [PATCH] $subject" "$patch_tmp" || {
    echo "error: patch subject mismatch" >&2
    exit 1
}

grep '^diff --git ' "$patch_tmp" \
    | sed -E 's#^diff --git a/([^ ]+) b/.*#\1#' \
    | sort -u > "$actual_patch_files"

if ! cmp -s "$actual_patch_files" "$expected_sorted"; then
    echo "error: patch files do not match expected files" >&2
    echo "expected:" >&2
    sed 's/^/    /' "$expected_sorted" >&2
    echo "patch:" >&2
    sed 's/^/    /' "$actual_patch_files" >&2
    exit 1
fi

if grep -q '^diff --git a/bludlua.c b/bludlua.c$' "$patch_tmp"; then
    echo "error: patch contains generated bludlua.c" >&2
    exit 1
fi

mv "$patch_tmp" "$patch"
rm -f "$state" "$expected" "$expected_sorted" "$actual" "$actual_patch_files"

new_commit=$(git log -1 --format='%h %s')

echo "PATCH READY"
echo "MODE: $mode"
echo "WORK LEFT AT: $new_commit"
echo "PATCH: $patch"
grep -m1 '^Subject:' "$patch"
echo "FILES:"
grep '^diff --git ' "$patch" | sed -E 's#^diff --git a/([^ ]+) b/.*#    \1#'
