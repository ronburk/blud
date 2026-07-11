#!/usr/bin/env bash
# Safely apply chatgpt.patch to a clean branch synchronized with its upstream.
set -euo pipefail

patch=chatgpt.patch

die() {
    echo "error: $*" >&2
    exit 1
}

offer_abort_am() {
    echo "A git am operation appears to be in progress."
    echo "Manual recovery: git am --abort"
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
    echo "Your local repo is not synced with GitHub upstream."
    git status --short --branch
    echo "RESET discards local commits with: git reset --hard @{u}"
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
    echo "Working tree is not clean:"
    git status --short
    die "commit/stash/revert local changes first"
fi

if [ "$(git rev-parse HEAD)" != "$(git rev-parse '@{u}')" ]; then
    offer_reset_to_upstream
fi

[ -f "$patch" ] ||
    die "$patch not found"

[ -s "$patch" ] ||
    die "$patch is empty"

if ! head -n 1 "$patch" | grep -q '^From '; then
    echo "$patch does not look like a git format-patch."
    echo "Expected first line: From "
    echo "Actual file type:"
    file "$patch" || true
    echo "First few bytes:"
    LC_ALL=C od -An -tx1 -N32 "$patch" || true
    die "not applying anything"
fi

grep -a -q '^Subject: ' "$patch" ||
    die "patch is missing a Subject line"

grep -a -q '^diff --git ' "$patch" ||
    die "patch is missing a git diff"

subject=$(grep -a -m1 '^Subject:' "$patch")
echo "$subject"
echo "Choose what to do:"
echo "    a  Apply the patch to the current branch"
echo "    p  Apply it on a new branch and create a GitHub PR"
echo "    q  Quit"
read -r -p "Choice [a/p/q]: " answer

case "$answer" in
    a|A)
        echo "About to run: git am --no-3way --keep-cr $patch"
        echo "If it fails: git am --abort"
        echo "If you dislike it afterward, rerun this script to reset to @{u}."
        read -r -p "Continue? [Y/n] " answer
        case "$answer" in
            ""|y|Y|yes|YES) ;;
            *) echo "aborted"; exit 0 ;;
        esac

        if ! git am --no-3way --keep-cr "$patch"; then
            echo "git am failed; recover with: git am --abort"
            exit 1
        fi

        rm -f "$patch"
        echo "Applied: $(git log -1 --oneline)"
        echo "Suggested checks: git show --stat; bash build.sh"
        ;;

    p|P)
        command -v gh >/dev/null 2>&1 ||
            die "gh is required to create a pull request"

        gh auth status >/dev/null 2>&1 ||
            die "gh is not authenticated"

        current_branch=$(git branch --show-current)
        [ -n "$current_branch" ] ||
            die "cannot create a PR from a detached HEAD"

        upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}')
        remote=${upstream%%/*}
        base_branch=${upstream#*/}
        [ "$remote" != "$upstream" ] ||
            die "could not determine the upstream remote"

        subject_text=${subject#Subject: }
        subject_text=$(printf '%s' "$subject_text" | sed 's/^\[PATCH[^]]*\][[:space:]]*//')
        slug=$(printf '%s' "$subject_text" |
            tr '[:upper:]' '[:lower:]' |
            sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-//; s/-$//; s/^\(.\{1,40\}\).*$/\1/; s/-$//')
        [ -n "$slug" ] || slug=patch
        pr_branch="chatgpt/$slug-$(date +%Y%m%d-%H%M%S)"

        echo "About to create and push branch: $pr_branch"
        echo "PR target: $base_branch"
        read -r -p "Continue? [Y/n] " answer
        case "$answer" in
            ""|y|Y|yes|YES) ;;
            *) echo "aborted"; exit 0 ;;
        esac

        git switch -c "$pr_branch"

        if ! git am --no-3way --keep-cr "$patch"; then
            echo "git am failed on branch $pr_branch."
            echo "Recover: git am --abort; git switch $current_branch; git branch -D $pr_branch"
            exit 1
        fi

        git push -u "$remote" "$pr_branch"

        if ! pr_url=$(gh pr create --fill --base "$base_branch" --head "$pr_branch"); then
            echo "The branch was pushed, but PR creation failed."
            echo "Retry: gh pr create --fill --base $base_branch --head $pr_branch"
            exit 1
        fi

        git switch "$current_branch"
        rm -f "$patch"
        echo "Created PR: $pr_url"
        echo "The current branch remains unchanged."
        ;;

    q|Q|"")
        echo "aborted"
        ;;

    *)
        die "invalid choice"
        ;;
esac
