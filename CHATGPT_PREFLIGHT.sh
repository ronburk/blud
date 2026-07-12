#!/usr/bin/env bash
set -u

run_fresh()
{
    echo "CHATGPT_PREFLIGHT: RUN .FRESH"
    exit 1
}

archive=/mnt/data/blud.zip
worktree=/mnt/data/blud

# The authoritative archive must exist.
[[ -f "${archive}" && -r "${archive}" ]] || run_fresh

# A rematerialized environment has previously given unrelated top-level
# files nearly identical timestamps. Ignore helper scripts that are
# deliberately created immediately after blud.zip is uploaded.
archive_mtime=$(stat -c %Y -- "${archive}") || run_fresh

other_file_count=0
different_timestamp_found=0

while IFS= read -r -d '' file; do
    name=${file##*/}

    case "${name}" in
        blud.zip|CHATGPT_PREFLIGHT.sh|CLOBBER*.sh)
            continue
            ;;
    esac

    other_file_count=$((other_file_count + 1))
    file_mtime=$(stat -c %Y -- "${file}") || run_fresh
    difference=$((archive_mtime - file_mtime))
    if ((difference < 0)); then
        difference=$((-difference))
    fi

    if ((difference > 5)); then
        different_timestamp_found=1
    fi
done < <(find /mnt/data -maxdepth 1 -type f -print0)

if ((other_file_count > 0 && different_timestamp_found == 0)); then
    run_fresh
fi

# The reconstructed worktree and bundled LuaJIT inputs must still exist.
[[ -d "${worktree}" ]] || run_fresh

for file in \
    "${worktree}/luajit/src/libluajit.a" \
    "${worktree}/luajit/src/lua.h" \
    "${worktree}/luajit/src/luaconf.h" \
    "${worktree}/luajit/src/lauxlib.h" \
    "${worktree}/luajit/src/lualib.h"
do
    [[ -f "${file}" ]] || run_fresh
done

# Git must recognize the worktree, and no tracked file may be deleted.
status=$(git -C "${worktree}" status --short --untracked-files=no 2>/dev/null) ||
    run_fresh

if printf '%s\n' "${status}" |
    awk '
        substr($0, 1, 1) == "D" || substr($0, 2, 1) == "D" {
            deleted = 1
        }
        END {
            exit deleted ? 0 : 1
        }
    '
then
    run_fresh
fi

echo "CHATGPT_PREFLIGHT: OK"
