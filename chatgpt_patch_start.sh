#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: $0 fresh|continue SUBJECT EXPECTED_FILE..." >&2
    exit 1
}

if [ "$#" -lt 3 ]; then
    usage
fi

mode=$1
shift
subject=$1
shift

case "$mode" in
    fresh|continue) ;;
    *) usage ;;
esac

zip=${CHATGPT_ZIP:-/mnt/data/blud.zip}
work=${CHATGPT_WORK:-/mnt/data/blud}
patch=${CHATGPT_PATCH:-/mnt/data/chatgpt.patch}
patch_tmp=${CHATGPT_PATCH_TMP:-/mnt/data/chatgpt.patch.tmp}
state=${CHATGPT_STATE:-/mnt/data/chatgpt_patch.state}
expected=${CHATGPT_EXPECTED:-/mnt/data/chatgpt_patch.expected}
actual=${CHATGPT_ACTUAL:-/mnt/data/chatgpt_patch.actual}
expected_sorted=${CHATGPT_EXPECTED_SORTED:-/mnt/data/chatgpt_patch.expected.sorted}
actual_patch_files=${CHATGPT_ACTUAL_PATCH_FILES:-/mnt/data/chatgpt_patch.files.actual}
rolling_marker_name=.git/chatgpt_rolling_source

add_local_ignores() {
    mkdir -p .git/info
    touch .git/info/exclude
    grep -qxF '/luajit' .git/info/exclude || printf '/luajit\n' >> .git/info/exclude
}

report_missing_rolling_source() {
    echo "error: rolling source tree is not available" >&2
    echo "upload a fresh blud.zip from your current repo, then use fresh mode" >&2
    exit 1
}

ensure_luajit_link() {
    add_local_ignores
    if [ ! -e luajit ] && [ -d /mnt/data/LuaJIT-2.1 ]; then
        ln -s /mnt/data/LuaJIT-2.1 luajit
    fi
}

rm -rf "$patch" "$patch_tmp"
rm -f "$actual" "$expected_sorted" "$actual_patch_files"

[ ! -f "$state" ] || {
    echo "error: active patch state already exists: $state" >&2
    echo "finish the current patch or remove the state files deliberately" >&2
    exit 1
}

case "$mode" in
    fresh)
        rm -rf "$work"
        mkdir -p "$work"
        unzip -q "$zip" -d "$work"
        cd "$work"
        git init -q
        git config user.name ChatGPT
        git config user.email chatgpt@example.com
        git add .
        git commit -q -m "baseline from uploaded blud.zip"
        printf '%s\n' "chatgpt rolling source" > "$rolling_marker_name"
        ensure_luajit_link
        ;;

    continue)
        [ -d "$work/.git" ] || report_missing_rolling_source
        cd "$work"
        git config user.name ChatGPT
        git config user.email chatgpt@example.com
        [ -f "$rolling_marker_name" ] || report_missing_rolling_source
        ensure_luajit_link
        if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
            echo "error: work tree is not clean; finish or discard local changes first" >&2
            git status --short >&2
            exit 1
        fi
        ;;
esac

baseline=$(git rev-parse HEAD)

{
    printf '%s\n' "$subject"
    printf '%s\n' "$baseline"
    printf '%s\n' "$mode"
} > "$state"

for file in "$@"; do
    printf '%s\n' "$file"
done > "$expected"

last_commit=$(git log -1 --format='%h %s')

echo "START READY"
echo "MODE: $mode"
echo "WORK: $work"
echo "BASELINE: $last_commit"
echo "SUBJECT: $subject"
echo "EXPECTED FILES:"
sed 's/^/    /' "$expected"
