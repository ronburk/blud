# ChatGPT Notes for blud

These are working notes for ChatGPT sessions on Ron Burk's `blud` project. Source code and Ron's current instructions override these notes if they disagree.

## Current patch workflow

The preferred workflow is a rolling sandbox repository in `/mnt/data/blud`.

Start from a fresh upload only when Ron uploads a new current `blud.zip` or when the rolling sandbox is missing/stale:

```sh
bash chatgpt_patch_start.sh fresh "Patch subject" file1 [file2 ...]
```

For subsequent patches made by ChatGPT in the same sandbox state, continue from the previous patch commit:

```sh
bash chatgpt_patch_start.sh continue "Patch subject" file1 [file2 ...]
```

Then edit only the requested/expected files and finish with:

```sh
bash chatgpt_patch_finish.sh
```

The finish script is the gatekeeper. It runs `bash build.sh`, restores/excludes generated files, verifies that the changed files exactly match the expected list, commits, writes `/mnt/data/chatgpt.patch`, and prints `PATCH READY` with the patch subject and file list. Do not offer Ron a patch link unless this mechanical verification has just succeeded.

After a successful finish, `/mnt/data/blud` is intentionally left advanced to the new patch commit. The next ChatGPT-made patch should usually use `continue`, not re-unpack `blud.zip`.

If `continue` reports that the rolling source tree is unavailable, missing, not a git repo, not marked as ChatGPT rolling source, or not clean, stop and ask Ron for a fresh `blud.zip` before making another patch.

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
