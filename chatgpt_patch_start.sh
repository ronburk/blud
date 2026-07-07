#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: $0 SUBJECT EXPECTED_FILE..." >&2
    exit 1
fi

subject=$1
shift

zip=${CHATGPT_ZIP:-/mnt/data/blud.zip}
work=${CHATGPT_WORK:-/mnt/data/blud}
patch=${CHATGPT_PATCH:-/mnt/data/chatgpt.patch}
patch_tmp=${CHATGPT_PATCH_TMP:-/mnt/data/chatgpt.patch.tmp}
state=${CHATGPT_STATE:-/mnt/data/chatgpt_patch.state}
expected=${CHATGPT_EXPECTED:-/mnt/data/chatgpt_patch.expected}
actual=${CHATGPT_ACTUAL:-/mnt/data/chatgpt_patch.actual}

rm -f "$patch" "$patch_tmp" "$state" "$expected" "$actual" "$expected.sorted"
rm -rf "$work"
mkdir -p "$work"
unzip -q "$zip" -d "$work"

cd "$work"
git init -q
git config user.name ChatGPT
git config user.email chatgpt@example.com
git add .
git commit -q -m "baseline from uploaded blud.zip"

{
    printf '%s\n' "$subject"
    git rev-parse HEAD
} > "$state"

for file in "$@"; do
    printf '%s\n' "$file"
done > "$expected"

echo "START READY"
echo "WORK: $work"
echo "SUBJECT: $subject"
echo "EXPECTED FILES:"
sed 's/^/    /' "$expected"
