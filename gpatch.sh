#!/usr/bin/env bash
set -euo pipefail

patch=/tmp/blud-change.patch

die() {
    echo "error: $*" >&2
    exit 1
}

offer_abort_am() {
    echo
    echo "A git am operation appears to be in progress."
    echo
    echo "To recover manually:"
    echo "    git am --abort"
    echo
    read -r -p "Abort it now? Type ABORT to confirm: " answer

    if [ "$answer" = "ABORT" ]; then
        git am --abort
        echo "Aborted git am."
    else
        echo "Not aborted."
    fi

    exit 1
}

offer_reset_to_upstream() {
    echo
    echo "Your local repo is not synced with GitHub upstream."
    echo
    git status --short --branch
    echo
    echo "To discard local commits and return to GitHub state:"
    echo "    git reset --hard @{u}"
    echo
    echo "This is intended for recovering after applying a bad ChatGPT patch."
    echo "It will discard local commits on this branch."
    echo
    read -r -p "Reset to upstream now? Type RESET to confirm: " answer

    if [ "$answer" = "RESET" ]; then
        git reset --hard '@{u}'
        echo "Reset to upstream."
    else
        echo "Not reset."
    fi

    exit 1
}

git rev-parse --is-inside-work-tree >/dev/null ||
    die "not inside a git repository"

command -v xclip >/dev/null ||
    die "xclip not found"

git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 ||
    die "current branch has no upstream"

if [ -d "$(git rev-parse --git-path rebase-apply)" ]; then
    offer_abort_am
fi

if [ -d "$(git rev-parse --git-path rebase-merge)" ] ||
   [ -f "$(git rev-parse --git-path MERGE_HEAD)" ]; then
    die "another git operation is in progress; resolve or abort it first"
fi

echo "Fetching upstream..."
git fetch --prune

if [ -n "$(git status --porcelain)" ]; then
    echo
    echo "Working tree is not clean:"
    git status --short
    echo
    die "commit/stash/revert local changes first"
fi

if [ "$(git rev-parse HEAD)" != "$(git rev-parse '@{u}')" ]; then
    offer_reset_to_upstream
fi

if ! xclip -selection clipboard -o > "$patch"; then
    die "could not read text from clipboard; maybe clipboard contains image/non-text data"
fi

[ -s "$patch" ] ||
    die "clipboard produced an empty patch"

if ! head -n 1 "$patch" | grep -q '^From '; then
    echo
    echo "Clipboard does not look like a git format-patch."
    echo
    echo "Expected first line to start with:"
    echo "    From "
    echo
    echo "Actual file type:"
    file "$patch" || true
    echo
    echo "First few bytes:"
    LC_ALL=C od -An -tx1 -N32 "$patch" || true
    echo
    die "not applying anything"
fi

grep -a -q '^Subject: ' "$patch" ||
    die "patch is missing a Subject line"

grep -a -q '^diff --git ' "$patch" ||
    die "patch is missing a git diff"

echo
echo "Patch subject:"
grep -a -m1 '^Subject:' "$patch" || true

echo
echo "About to run:"
echo "    git am --no-3way $patch"
echo
echo "If git am fails, recover with:"
echo "    git am --abort"
echo
echo "If it succeeds but you dislike the result, run this script again."
echo "It will notice that your repo is no longer synced with upstream and offer:"
echo "    git reset --hard @{u}"
echo
read -r -p "Continue? [y/N] " answer
case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "aborted"; exit 0 ;;
esac

if ! git am --no-3way "$patch"; then
    echo
    echo "git am failed."
    echo
    echo "To recover:"
    echo "    git am --abort"
    echo
    exit 1
fi

echo
echo "Applied:"
git log -1 --oneline
echo
echo "Suggested next checks:"
echo "    git show --stat"
echo "    bash build.sh"
