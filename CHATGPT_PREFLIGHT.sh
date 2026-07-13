#!/usr/bin/env bash
set -u

run_fresh()
{
    printf 'CHATGPT_PREFLIGHT: FAILED: %s\n' "$1" >&2
    echo "CHATGPT_PREFLIGHT: RUN .FRESH"
    exit 1
}

archive=/mnt/data/blud.zip
worktree=/mnt/data/blud

# The authoritative archive path must remain a relative symbolic link to
# the uniquely named file created from the current upload.
[[ -L "${archive}" ]] || run_fresh "${archive} is not a symbolic link"

link_target=$(readlink -- "${archive}") ||
    run_fresh "readlink failed for ${archive}"

if [[ ! "${link_target}" =~ ^blud-upload-[0-9]{8}T[0-9]{6}\.[0-9]{9}Z\.zip$ ]]; then
    run_fresh "${archive} points to invalid archive name ${link_target}"
fi

archive_target=/mnt/data/${link_target}
[[ -f "${archive_target}" ]] || run_fresh "${archive_target} does not exist"
[[ ! -L "${archive_target}" ]] || run_fresh "${archive_target} is itself a symbolic link"
[[ -r "${archive_target}" ]] || run_fresh "${archive_target} is not readable"

resolved_archive=$(readlink -f -- "${archive}") ||
    run_fresh "cannot resolve ${archive}"
[[ "${resolved_archive}" == "${archive_target}" ]] ||
    run_fresh "${archive} resolves outside its expected target"

# A rematerialized environment has previously given unrelated top-level
# files nearly identical timestamps. Ignore workflow files and all blud
# archive names while checking for that signature.
archive_mtime=$(stat -c %Y -- "${archive_target}") ||
    run_fresh "stat failed for ${archive_target}"

other_file_count=0
different_timestamp_found=0

while IFS= read -r -d '' file; do
    name=${file##*/}

    case "${name}" in
        blud.zip|blud-upload-*.zip|blud\([0-9]*\).zip|CHATGPT_PREFLIGHT.sh|CLOBBER*.sh)
            continue
            ;;
    esac

    other_file_count=$((other_file_count + 1))
    file_mtime=$(stat -c %Y -- "${file}") ||
        run_fresh "stat failed for ${file}"
    difference=$((archive_mtime - file_mtime))
    if ((difference < 0)); then
        difference=$((-difference))
    fi

    if ((difference > 5)); then
        different_timestamp_found=1
    fi
done < <(find /mnt/data -maxdepth 1 -type f -print0)

if ((other_file_count > 0 && different_timestamp_found == 0)); then
    run_fresh "all ${other_file_count} unrelated top-level files have timestamps within 5 seconds of ${archive}"
fi

# The reconstructed worktree and bundled LuaJIT inputs must still exist.
[[ -d "${worktree}" ]] || run_fresh "${worktree} does not exist"

for file in \
    "${worktree}/luajit/src/libluajit.a" \
    "${worktree}/luajit/src/lua.h" \
    "${worktree}/luajit/src/luaconf.h" \
    "${worktree}/luajit/src/lauxlib.h" \
    "${worktree}/luajit/src/lualib.h"
do
    [[ -f "${file}" ]] || run_fresh "required file ${file} does not exist"
done

# Git must recognize the worktree, and no tracked file may be deleted.
status=$(git -C "${worktree}" status --short --untracked-files=no 2>/dev/null) ||
    run_fresh "git status failed in ${worktree}"

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
    run_fresh "git reports one or more deleted tracked files in ${worktree}"
fi

echo "CHATGPT_PREFLIGHT: OK"
