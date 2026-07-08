#!/usr/bin/env bash
set -euo pipefail

work=${CHATGPT_WORK:-/mnt/data/blud}
zip=${CHATGPT_ZIP:-/mnt/data/blud.zip}
patch=${CHATGPT_PATCH:-/mnt/data/chatgpt.patch}
patch_tmp=${CHATGPT_PATCH_TMP:-/mnt/data/chatgpt.patch.tmp}

usage() {
    cat >&2 <<USAGE
usage:
  $0 status
  $0 fresh
  $0 finish SUBJECT FILE...
USAGE
    exit 2
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
    if [ ! -e "$work" ]; then
        echo "NEED_FRESH_ZIP"
        return 0
    fi

    if [ ! -d "$work/.git" ]; then
        echo "BAD_WORKTREE"
        return 0
    fi

    cd "$work"

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "BAD_WORKTREE"
        return 0
    fi

    ensure_luajit_link

    if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
        echo "DIRTY_WORKTREE"
        git status --short >&2
        return 0
    fi

    echo "READY"
}

fresh() {
    if [ ! -f "$zip" ]; then
        echo "NEED_FRESH_ZIP" >&2
        exit 1
    fi

    rm -rf "$work" "$patch" "$patch_tmp"
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

    echo "READY"
}

restore_generated() {
    git checkout -- bludlua.c 2>/dev/null || true
    rm -f .build_id blud blud.d bludlua.d cstr blud.zip
}

finish() {
    if [ "$#" -lt 2 ]; then
        usage
    fi

    subject=$1
    shift

    [ -d "$work/.git" ] || {
        echo "NEED_FRESH_ZIP" >&2
        exit 1
    }

    cd "$work"
    git config user.name ChatGPT
    git config user.email chatgpt@example.invalid
    ensure_luajit_link

    rm -rf "$patch" "$patch_tmp"

    bash build.sh
    restore_generated

    expected=$(mktemp)
    actual=$(mktemp)
    patch_files=$(mktemp)
    cleanup() {
        rm -f "$expected" "$actual" "$patch_files"
    }
    trap cleanup EXIT

    for file in "$@"; do
        printf '%s\n' "$file"
    done | sort -u > "$expected"

    {
        git diff --name-only
        git ls-files --others --exclude-standard
    } | sort -u > "$actual"

    if ! cmp -s "$expected" "$actual"; then
        echo "error: changed files do not match expected files" >&2
        echo "expected:" >&2
        sed 's/^/    /' "$expected" >&2
        echo "actual:" >&2
        sed 's/^/    /' "$actual" >&2
        exit 1
    fi

    git diff --check

    while IFS= read -r file; do
        git add -- "$file"
    done < "$expected"

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

    if ! cmp -s "$expected" "$patch_files"; then
        echo "error: patch files do not match expected files" >&2
        echo "expected:" >&2
        sed 's/^/    /' "$expected" >&2
        echo "patch:" >&2
        sed 's/^/    /' "$patch_files" >&2
        exit 1
    fi

    if grep -q '^diff --git a/bludlua.c b/bludlua.c$' "$patch_tmp"; then
        echo "error: patch contains generated bludlua.c" >&2
        exit 1
    fi

    mv "$patch_tmp" "$patch"

    echo "PATCH READY"
    echo "PATCH: $patch"
    grep -m1 '^Subject:' "$patch"
    echo "FILES:"
    sed 's/^/    /' "$patch_files"
}

case "${1:-}" in
    status)
        [ "$#" -eq 1 ] || usage
        status
        ;;
    fresh)
        [ "$#" -eq 1 ] || usage
        fresh
        ;;
    finish)
        shift
        finish "$@"
        ;;
    *)
        usage
        ;;
esac
