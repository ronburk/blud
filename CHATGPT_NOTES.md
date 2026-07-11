# ChatGPT Notes for blud

These are continuity notes for ChatGPT sessions on Ron Burk's `blud` project. Current project instructions and Ron's explicit requests override this file.

## Mandatory command workflows

### `.FRESH`

On `.FRESH`, execute exactly:

```sh
rm -f /mnt/data/CLOBBER*.sh /mnt/data/blud*.zip
```

Then ask Ron to upload a fresh `blud.zip` and stop.

When the upload arrives, it may be named `blud(nnn).zip` even though all visible `blud*.zip` files were removed. The uploader apparently uses hidden collision history, not just visible files. Find the newly uploaded archive and rename it to `/mnt/data/blud.zip`, then run:

```sh
unzip -p /mnt/data/blud.zip CLOBBER.sh > /mnt/data/CLOBBER.sh
bash /mnt/data/CLOBBER.sh
```

Inspect stdout, stderr, and exit status. Never claim success without actual command output. If `CLOBBER.sh` prints `CHATGPT_ACTION=RESTART_DOT_FRESH`, report that and restart `.FRESH`; do not improvise around it.

Current `CLOBBER.sh`:

- Rejects multiple `/mnt/data/blud*.zip` archives, deletes them all, and requests `.FRESH` restart.
- Only after that check passes, deletes top-level files matching `/mnt/data/*(*).*`.
- Rejects a probably rematerialized stale `blud.zip` when its mtime is suspiciously close to the persistent LuaJIT archive.
- Recreates `/mnt/data/blud` from `/mnt/data/blud.zip`.
- Creates and builds `/mnt/data/blud/luajit` from `/mnt/data/LuaJIT-2.1.zip` when needed.
- Initializes a clean git `main` baseline commit and runs `bash build.sh`.

Do not rely on `/mnt/data/CLOBBER.sh` or `/mnt/data/blud` persisting between turns.

### `.PATCH`

Complete the requested change first. In `/mnt/data/blud`:

1. Run relevant build/tests.
2. Ensure only intended non-ignored source changes remain.
3. Stage those changes and commit them as one commit.
4. Run:

```sh
bash chatgpt_patch_finish.sh
```

5. If the script exits nonzero, report the failure and do not supply a patch.
6. Link only the exact uniquely named path printed as `PATCH:` by the script.

Never link `/mnt/data/chatgpt.patch`; the artifact layer may serve stale bytes when a pathname is reused. The user downloads the uniquely named sandbox artifact locally under the fixed name `chatgpt.patch`.

`chatgpt_patch_finish.sh` removes old sandbox `chatgpt*.patch` files, generates `/mnt/data/chatgpt-<full-HEAD>.patch`, verifies its header names `HEAD`, applies that exact file with `git am --no-3way` in a temporary clone, verifies the resulting tree, and prints its path, subject, and SHA-256.

Do not provide a bare diff. The patch must be a complete `git format-patch` commit usable with `git am --no-3way`.

### `.REVERT`

Use git to return `/mnt/data/blud` to its state at the previous `.PATCH`, undoing the current patch commit. If there has been no previous `.PATCH`, return to the baseline commit. Verify and report the resulting status.

### `.LS`

Actually execute and show the output unaltered:

```sh
TZ=America/Los_Angeles ls -al /mnt/data /mnt/data/blud
```

Do not reconstruct, summarize, reformat, or manufacture the output. A failed `ls` is itself part of the raw result.

## Working-environment hazards

- `/mnt/data` is ephemeral. Generated files and directories, especially `/mnt/data/blud` and helper scripts, may disappear between turns.
- Uploaded files often persist longer, but deleted files may later rematerialize with new-looking timestamps. Filesystem history and mtimes are not fully trustworthy.
- Upload collision renaming uses state outside the visible filesystem. A new `blud.zip` may arrive as `blud(12).zip` after all visible copies were deleted.
- Reusing a downloadable sandbox pathname can return an older immutable snapshot. Always use a new unique artifact filename.
- Actual command execution and exit status are the only trustworthy evidence. Never infer that a command ran from remembered state or expected output.
- Long commands may time out near completion. After a timeout, inspect the actual state before deciding whether to resume or rerun.
- Scripts should be noninteractive, validate their assumptions, fail loudly, and print distinctive machine-readable action lines when ChatGPT must react.
- Instruction files inside `/mnt/data/blud` do not protect the directory from platform cleanup.

## Ron's local patch workflow

Ron saves the uniquely named download locally as `chatgpt.patch` and runs:

```sh
bash gpatch.sh
```

Current `gpatch.sh`:

- Fetches and requires the current branch to equal its upstream before applying.
- Offers either applying to the current branch or creating/pushing a new branch and GitHub PR.
- Uses `git am --no-3way --keep-cr chatgpt.patch`.
- Removes local `chatgpt.patch` only after successful application, or after successful push and PR creation.
- On a later run, checks upstream divergence before checking whether the patch file exists, so it can still offer `git reset --hard @{u}` after the patch file was removed.
- Keeps the patch on failure for diagnosis/retry.

`--no-3way` is intentional because sandbox and real-repository blob IDs may differ. `--keep-cr` avoids CRLF damage.

## Current open design work

The next likely design task concerns default-target selection and `:BUILD:` behavior.

Two concepts are currently conflated in `blud.primary_targets`:

1. The singular first real buildable target encountered while executing the translated bludfile. This is an intrinsic fact about the bludfile and must remain available even when command-line targets are supplied.
2. The list of targets selected for the current invocation, possibly supplied on the command line.

These should be represented separately, with names along the lines of:

```lua
blud.default_target       -- first real buildable target in the bludfile
blud.requested_targets    -- explicit command-line selections
blud.build_targets        -- resolved targets for this invocation, if separately useful
```

`%:`, `:TEST:`, and `:BUILD:` are not ordinary default-target candidates. Running `./blud release` should not erase knowledge of the bludfile's ordinary default target; the `release` build configuration may need that target.

Also inspect the current `SET_PRIMARY_TARGETS` interface before changing it: earlier review found a singular atom being passed while one override treated it as an array. Prefer a singular interface/name if that is still true.

Known behavior needing later attention: `./blud` selected the `debug/` output directory but compile commands omitted `-g`, and the resulting binary had no `.debug_*` sections. Thus the build was named debug without actually being a debug build.

## Source and build notes

- Normal work happens only in `/mnt/data/blud`; `/mnt/data/blud.zip` is authoritative only for `.FRESH` reconstruction.
- Generated/build files are covered by `.gitignore`; only intended non-ignored source changes belong in patches.
- Typical checks from `/mnt/data/blud` are `bash build.sh`, `./blud`, and task-specific invocations such as `./blud release`.
- `build.sh` regenerates ignored files such as `bludlua.c`.
- Current architecture favors getting built-in operators correct before designing broad extension points, and favors direct readable operator-specific code over deep generalized dispatch.
- `CPPFLAGS` is for preprocessor flags, `CFLAGS` for C compilation flags, `CXXFLAGS` for C++, and `LDFLAGS` for linker options/search paths.

## Style

- Be concise.
- Inspect current files before proposing changes.
- Prefer one minimal change at a time.
- Use 4-space indentation and snake_case.
- Focus reviews on likely practical problems, not generic advice.
- Ask a clarifying question when an important design decision is genuinely underspecified.
