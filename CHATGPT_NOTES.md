# ChatGPT Notes for blud

These are working notes for ChatGPT sessions on Ron Burk's `blud` project. Source code and Ron's current instructions override these notes if they disagree.

## Current patch workflow

The patch workflow treats `/mnt/data/blud.zip` as the accepted baseline and `/mnt/data/blud` as disposable scratch space. Do not preserve the worktree as source-of-truth.

Commands:

```sh
./chatgpt_patch.sh status
./chatgpt_patch.sh begin "Patch subject" file1 [file2 ...]
# edit files in /mnt/data/blud
./chatgpt_patch.sh propose
./chatgpt_patch.sh accept
./chatgpt_patch.sh reject
```

State meanings:

```text
READY              accepted baseline zip exists; no pending patch
EDITING            begin succeeded; make the requested edits, then propose or reject
CANDIDATE_READY    patch and candidate zip exist; Ron must accept or reject before another patch
NEED_BASELINE_ZIP  no accepted /mnt/data/blud.zip is available
BAD_EDIT_STATE     internal scratch/state mismatch; stop and ask Ron how to reset
DIRTY_OR_MISMATCH  changed files differ from the file list recorded by begin
```

`begin` always deletes and recreates `/mnt/data/blud` from `/mnt/data/blud.zip`, initializes a fresh git baseline, and records the patch subject and intended files.

`propose` runs `bash build.sh`, restores/excludes generated files, verifies that the changed files exactly match the recorded file list, writes `/mnt/data/chatgpt.patch`, and writes `/mnt/data/blud_candidate.zip`. It does not overwrite `/mnt/data/blud.zip`.

`accept` promotes `/mnt/data/blud_candidate.zip` to `/mnt/data/blud.zip`. `reject` deletes the candidate, patch, scratch worktree, and edit state.

Do not offer Ron a patch link unless `propose` has just printed `PATCH READY`. If `status` prints `CANDIDATE_READY`, do not begin another patch; Ron must accept or reject the pending candidate first.

## Ron's local apply workflow

Ron downloads the sandbox patch as `chatgpt.patch` and applies it with `gpatch.sh`. Current `gpatch.sh` runs:

```sh
git am --no-3way --keep-cr chatgpt.patch
```

`--no-3way` is intentional: ChatGPT patches are generated from a sandbox repo, and Ron's real repo may not have the same blob IDs. Failing on textual context mismatch is preferable to confusing three-way fallback behavior.

`--keep-cr` was added after CRLF in `cstr.cpp` caused patch application failures. `cstr.cpp` has since been normalized to LF, but keeping this option is still useful for bootstrapping and for any future CRLF files.

If `git am` fails, Ron runs:

```sh
git am --abort
```

## Generated files and patch exclusions

- `build.sh` regenerates `bludlua.c`.
- `bludlua.c` is generated and must not be included in source patches.
- The finish script restores/excludes `bludlua.c` before committing.
- Other build products such as `.build_id`, `blud`, `blud.d`, `bludlua.d`, `cstr`, and `blud.zip` are removed by the finish script before patch generation.

## Build/test workflow

Typical checks from `/mnt/data/blud`:

```sh
bash build.sh
./blud
./blud -d
```

LuaJIT may need to exist or be symlinked as:

```text
/mnt/data/blud/luajit -> /mnt/data/LuaJIT-2.1
```

The patch scripts try to create this symlink when `/mnt/data/LuaJIT-2.1` exists, and ignore it via `.git/info/exclude`.

## Current source state and design direction

Current architecture direction is deliberately simpler and more hard-coded:

- Get built-in operators correct before designing broad extension points.
- Keep common behavior only where it is already proven useful.
- Prefer direct, readable operator-specific code over a deep atom/operator/super dispatch maze.

Recent source state:

- `atom.lua` exists and owns the atom defaults.
- `atom.lua` returns the super-atom table; `runtime.lua` assigns it with `blud.super_atom = require("atom")`.
- `target:BUILD()` dispatches to `target.RULE.operator:BUILD(target)` after rule discovery/fallback.
- The `:` operator owns the normal build behavior.
- The `::` operator has its own `BUILD()` and local prerequisite preparation logic rather than delegating blindly to `:`.
- The `::` operator now lowers sources to object prerequisites and links objects, e.g. `blud :: blud.c bludlua.c oslinux.c` builds `blud.o`, `bludlua.o`, `oslinux.o`, then links `blud`.
- Build actions echo the command line before executing it, as normal build tools do.

## Variables and builtins

The project is moving toward GNU-make-like variable naming:

- `CPPFLAGS` contains preprocessor flags such as `-I...` and `-D...`.
- `CFLAGS` contains C compiler flags.
- `CXXFLAGS` contains C++ compiler flags.
- `LDFLAGS` contains linker options/search paths.

`builtin.blud` compile rules should use `$(CPPFLAGS)` together with `$(CFLAGS)`/`$(CXXFLAGS)`, not separate `CINCLUDES` or `CXXINCLUDES` variables.

## Debugger notes

- `debug.lua` was renamed to `debugger.lua` to avoid collision with Lua's standard `debug` module.
- Runtime should load it with `require("debugger")`.
- `-d` should set `debugger.probe = debugger.real_probe`.
- Interactive commands include `q`, `c`, `s`, `n`, `bt`/`where`, `e <lua>`, and `?`.

## Debug print cleanup

Most ad hoc debugging prints should stay commented out. Normal build command echoing should remain active in `blud.execute()`.

When searching for remaining debug prints, distinguish real executable prints from lines already inside comments or dead commented-out blocks.

## Style preferences

- Be concise.
- Inspect current files before proposing changes.
- Prefer one minimal change at a time.
- Use 4-space indentation and snake_case.
- Avoid generic advice in code reviews; focus on likely practical problems.
- Ask clarifying questions when the prompt is underspecified or would require guessing important design decisions.
