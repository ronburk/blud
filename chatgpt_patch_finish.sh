#!/usr/bin/env bash
set -euo pipefail

work=${CHATGPT_WORK:-/mnt/data/blud}
patch=${CHATGPT_PATCH:-/mnt/data/chatgpt.patch}
patch_tmp=${CHATGPT_PATCH_TMP:-/mnt/data/chatgpt.patch.tmp}
state=${CHATGPT_STATE:-/mnt/data/chatgpt_patch.state}
expected=${CHATGPT_EXPECTED:-/mnt/data/chatgpt_patch.expected}
actual=${CHATGPT_ACTUAL:-/mnt/data/chatgpt_patch.actual}
expected_sorted=${CHATGPT_EXPECTED_SORTED:-/mnt/data/chatgpt_patch.expected.sorted}

rm -f "$patch" "$patch_tmp" "$actual" "$expected_sorted"

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

cd "$work"

[ "$(git rev-parse HEAD)" = "$baseline" ] || {
    echo "error: HEAD is not the baseline recorded by chatgpt_patch_start.sh" >&2
    exit 1
}

bash build.sh

git checkout -- bludlua.c 2>/dev/null || true
rm -f .build_id blud blud.d bludlua.d cstr blud.zip

git diff --name-only | sort > "$actual"
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

while IFS= read -r file; do
    grep -Fq "diff --git a/$file b/$file" "$patch_tmp" || {
        echo "error: patch does not contain expected file: $file" >&2
        exit 1
    }
done < "$expected_sorted"

mv "$patch_tmp" "$patch"
rm -f "$state" "$expected" "$expected_sorted" "$actual"

echo "PATCH READY"
echo "PATCH: $patch"
grep -m1 '^Subject:' "$patch"
echo "FILES:"
grep '^diff --git ' "$patch" | sed -E 's#^diff --git a/([^ ]+) b/.*#    \1#'
