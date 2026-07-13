# ChatGPT Notes for blud

These are continuity notes for ChatGPT sessions on Ron Burk's `blud` project. Current project instructions and Ron's explicit requests override this file.

## Mandatory command workflows

### `.FRESH`

Ron now creates the unique archive name before uploading. A valid upload is
named:

```text
blud-upload-YYYYMMDDTHHMMSS.NNNNNNNNNZ.zip
```

Do not rename or copy that upload. Use the exact filesystem path assigned to
it.

If `.FRESH` is requested without a new archive attached, execute exactly:

```sh
rm -f /mnt/data/CLOBBER*.sh
rm -f /mnt/data/blud.zip
rm -f /mnt/data/blud\([0-9]*\).zip
```

Then ask Ron to upload a fresh uniquely named archive and stop.

When the unique upload arrives:

1. Verify its basename matches the exact format above.
2. Remove any existing `/mnt/data/blud.zip`.
3. Create a relative symlink:

```text
/mnt/data/blud.zip -> <basename of the newly uploaded archive>
```

4. Verify the symlink target is the exact new upload, is a regular readable
   file, and contains `CLOBBER.sh`.
5. Run the bootstrap exactly once:

```sh
unzip -p /mnt/data/blud.zip CLOBBER.sh > /mnt/data/CLOBBER.sh
bash /mnt/data/CLOBBER.sh
```

6. Run the normal preflight described below.

Do not repeat a successful bootstrap. A previous response repeated it because
the instructions appeared duplicated; one successful run is sufficient.

An uploaded `blud*.zip` without an explicit `.FRESH` is itself an implicit
`.FRESH`.

Current `CLOBBER.sh`:

- Requires `/mnt/data/blud.zip` to be a relative symlink to a uniquely named
  `blud-upload-*.zip` regular file.
- Removes stale collision-renamed `blud(n).zip` archives.
- Recreates `/mnt/data/blud` from the symlinked archive.
- Requires the bundled LuaJIT static archive and four headers under
  `/mnt/data/blud/luajit/src`.
- Initializes a clean git `main` baseline commit and runs `bash build.sh`.

Do not rely on `/mnt/data/CLOBBER.sh` or `/mnt/data/blud` persisting between turns.

### Preflight

Before reading or modifying blud source, run:

```sh
bash /mnt/data/blud/CHATGPT_PREFLIGHT.sh
```

Proceed only when it exits successfully and prints
`CHATGPT_PREFLIGHT: OK`. Any other result means stop and execute `.FRESH`; do
not attempt manual recovery, reconstruction, archive selection, or git repair.
When asking for a fresh archive, include the specific failed command or
preflight diagnostic.

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
- Upload identity appears to be tracked outside the visible filesystem. Renaming
  an uploaded `blud.zip` to a unique pathname inside `/mnt/data` did not make
  it safe: that pathname later contained bytes from an older archive. The
  direct comparison showed two debug `print()` calls enabled in the restored
  archive but commented out in the worktree's baseline `compiler.lua`.
- Therefore Ron must create the unique filename before upload, and ChatGPT must
  preserve that exact uploaded file without renaming or copying it. Only the
  `/mnt/data/blud.zip` symlink is created locally.
- Upload collision renaming uses state outside the visible filesystem. A new
  non-unique `blud.zip` may arrive as `blud(12).zip` after all visible copies
  were deleted; this is another reason not to use non-unique uploads.
- Reusing a downloadable sandbox pathname can return an older immutable snapshot. Always use a new unique artifact filename.
- Actual command execution and exit status are the only trustworthy evidence. Never infer that a command ran from remembered state or expected output.
- Never fabricate, reconstruct, or silently reformat shell output. This has
  caused repeated trust failures, especially for `ls`.
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
- `compile_action()` currently supports one action line only. A second
  indented line produces the clean compiler diagnostic:

```text
Multiple action lines are not supported yet
note: combine commands with && or invoke a script
```

- The latest patch, `de7f52a Comment action compilation`, adds explanatory
  comments to `compile_action()` covering deferred macro expansion, generated
  closure execution, status propagation, the one-line limitation, and the
  `nil` no-action representation.
- Current architecture favors getting built-in operators correct before designing broad extension points, and favors direct readable operator-specific code over deep generalized dispatch.
- `CPPFLAGS` is for preprocessor flags, `CFLAGS` for C compilation flags, `CXXFLAGS` for C++, and `LDFLAGS` for linker options/search paths.

## Style

- Be concise.
- Inspect current files before proposing changes.
- Prefer one minimal change at a time.
- Use 4-space indentation and snake_case.
- Focus reviews on likely practical problems, not generic advice.
- Ask a clarifying question when an important design decision is genuinely underspecified.
