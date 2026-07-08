#!/usr/bin/env bash
set -euo pipefail

work=${CHATGPT_WORK:-/mnt/data/blud}
zip=${CHATGPT_ZIP:-/mnt/data/blud.zip}
candidate=${CHATGPT_CANDIDATE_ZIP:-/mnt/data/blud_candidate.zip}
patch=${CHATGPT_PATCH:-/mnt/data/chatgpt.patch}
state_dir=${CHATGPT_STATE_DIR:-/mnt/data/chatgpt_patch_state}

usage() {
    cat >&2 <<USAGE
usage:
  $0 status
  $0 begin SUBJECT FILE...
  $0 propose
  $0 accept
  $0 reject
USAGE
    exit 2
}

say_state() {
    echo "$1"
}

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

status() {
    if [ -f "$candidate" ]; then
        say_state "CANDIDATE_READY"
        return 0
    fi

    if [ -d "$state_dir" ]; then
        if [ -d "$work/.git" ]; then
            say_state "EDITING"
        else
            say_state "BAD_EDIT_STATE"
        fi
        return 0
    fi

    if [ ! -f "$zip" ]; then
        say_state "NEED_BASELINE_ZIP"
        return 0
    fi

    say_state "READY"
}

init_work_from_zip() {
    [ -f "$zip" ] || {
        say_state "NEED_BASELINE_ZIP" >&2
        exit 1
    }

    rm -rf "$work"
    mkdir -p "$work"
    unzip -q "$zip" -d "$work"

    cd "$work"
    git init -q -b main
    git config user.name ChatGPT
    git config user.email chatgpt@example.invalid
    add_local_ignores
    ensure_luajit_link
    git add .
    git commit -q -m "Initial commit"
}

begin() {
    if [ "$#" -lt 2 ]; then
        usage
    fi

    if [ -f "$candidate" ]; then
        say_state "CANDIDATE_READY" >&2
        echo "error: accept or reject the existing candidate before starting another patch" >&2
        exit 1
    fi

    if [ -d "$state_dir" ]; then
        say_state "EDITING" >&2
        echo "error: finish or reject the current edit before starting another patch" >&2
        exit 1
    fi

    subject=$1
    shift

    rm -rf "$patch"
    init_work_from_zip

    rm -rf "$state_dir"
    mkdir -p "$state_dir"
    printf '%s\n' "$subject" > "$state_dir/subject"
    for file in "$@"; do
        printf '%s\n' "$file"
    done | sort -u > "$state_dir/files"
    git rev-parse HEAD > "$state_dir/baseline"

    say_state "EDITING"
}

restore_generated() {
    git checkout -- bludlua.c 2>/dev/null || true
    rm -f .build_id blud blud.d bludlua.d cstr blud.zip
}

read_state() {
    [ -d "$state_dir" ] || {
        say_state "READY" >&2
        echo "error: no patch is in progress; run begin first" >&2
        exit 1
    }

    [ -f "$state_dir/subject" ] && [ -f "$state_dir/files" ] && [ -f "$state_dir/baseline" ] || {
        say_state "BAD_EDIT_STATE" >&2
        echo "error: incomplete patch state" >&2
        exit 1
    }
}

propose() {
    [ "$#" -eq 0 ] || usage
    read_state

    if [ -f "$candidate" ]; then
        say_state "CANDIDATE_READY" >&2
        echo "error: accept or reject the existing candidate before proposing another patch" >&2
        exit 1
    fi

    [ -d "$work/.git" ] || {
        say_state "BAD_EDIT_STATE" >&2
        echo "error: missing worktree" >&2
        exit 1
    }

    cd "$work"
    git config user.name ChatGPT
    git config user.email chatgpt@example.invalid
    ensure_luajit_link

    baseline=$(cat "$state_dir/baseline")
    current=$(git rev-parse HEAD)
    if [ "$current" != "$baseline" ]; then
        say_state "BAD_EDIT_STATE" >&2
        echo "error: worktree HEAD changed since begin" >&2
        exit 1
    fi

    patch_tmp=$(mktemp /mnt/data/chatgpt.patch.XXXXXX)
    candidate_tmp=$(mktemp -u /mnt/data/blud_candidate.zip.XXXXXX)
    actual=$(mktemp)
    patch_files=$(mktemp)
    cleanup() {
        rm -f "$patch_tmp" "$candidate_tmp" "$actual" "$patch_files"
    }
    trap cleanup EXIT

    rm -rf "$patch"

    bash build.sh
    restore_generated

    {
        git diff --name-only
        git ls-files --others --exclude-standard
    } | sort -u > "$actual"

    if ! cmp -s "$state_dir/files" "$actual"; then
        say_state "DIRTY_OR_MISMATCH" >&2
        echo "error: changed files do not match intended files" >&2
        echo "expected:" >&2
        sed 's/^/    /' "$state_dir/files" >&2
        echo "actual:" >&2
        sed 's/^/    /' "$actual" >&2
        exit 1
    fi

    git diff --check

    while IFS= read -r file; do
        git add -- "$file"
    done < "$state_dir/files"

    subject=$(cat "$state_dir/subject")
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
        | sort -u > "$patch_files"

    if ! cmp -s "$state_dir/files" "$patch_files"; then
        echo "error: patch files do not match intended files" >&2
        echo "expected:" >&2
        sed 's/^/    /' "$state_dir/files" >&2
        echo "patch:" >&2
        sed 's/^/    /' "$patch_files" >&2
        exit 1
    fi

    if grep -q '^diff --git a/bludlua.c b/bludlua.c$' "$patch_tmp"; then
        echo "error: patch contains generated bludlua.c" >&2
        exit 1
    fi

    # The accepted baseline zip must not be overwritten until Ron accepts the patch.
    zip -qr "$candidate_tmp" . -x '.git/*' 'luajit' 'luajit/*'

    mv "$patch_tmp" "$patch"
    mv "$candidate_tmp" "$candidate"
    rm -rf "$state_dir"

    say_state "CANDIDATE_READY"
    echo "PATCH READY"
    echo "PATCH: $patch"
    echo "CANDIDATE: $candidate"
    grep -m1 '^Subject:' "$patch"
    echo "FILES:"
    sed 's/^/    /' "$patch_files"
}

accept() {
    [ "$#" -eq 0 ] || usage

    [ -f "$candidate" ] || {
        say_state "READY" >&2
        echo "error: no candidate patch to accept" >&2
        exit 1
    }

    mv "$candidate" "$zip"
    rm -rf "$state_dir" "$work" "$patch"
    say_state "READY"
}

reject() {
    [ "$#" -eq 0 ] || usage
    rm -rf "$candidate" "$patch" "$state_dir" "$work"
    say_state "READY"
}

case "${1:-}" in
    status)
        [ "$#" -eq 1 ] || usage
        status
        ;;
    begin)
        shift
        begin "$@"
        ;;
    propose)
        shift
        propose "$@"
        ;;
    accept)
        shift
        accept "$@"
        ;;
    reject)
        shift
        reject "$@"
        ;;
    *)
        usage
        ;;
esac
