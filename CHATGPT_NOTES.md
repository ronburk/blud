# ChatGPT Notes for blud

These are working notes for ChatGPT sessions on Ron Burk's `blud` project. Source code and Ron's current instructions override these notes if they disagree.

## Current ChatGPT patch workflow

Ron controls synchronization explicitly.

### Source authority

For normal work, `/mnt/data/blud` is the only source tree.

Do not inspect, unpack, or compare against `/mnt/data/blud.zip` unless Ron explicitly says:

```text
CLOBBER
```

`/mnt/data/blud.zip` is only an input to `CLOBBER`.

### CLOBBER

When Ron says `CLOBBER`, run:

```sh
bash /mnt/data/CLOBBER.sh
```

Then report:

```text
WORKTREE: /mnt/data/blud
HEAD: <short sha>
STATUS: clean
```

Do not make source edits in the same response unless Ron explicitly asks.

`CLOBBER.sh` deletes `/mnt/data/blud`, recreates it from `/mnt/data/blud.zip`, creates the LuaJIT symlink if available, initializes git, commits a baseline, removes stale `/mnt/data/chatgpt.patch`, runs `bash build.sh`, and requires clean git status afterward.

### Normal patch work

Before editing, run:

```sh
cd /mnt/data/blud
test -d .git
git status --porcelain
```

If `/mnt/data/blud/.git` is missing, stop and ask Ron to use `CLOBBER` with a fresh `blud.zip`.

If `git status --porcelain` prints anything, stop and report the exact output. Do not guess whether the dirty files are harmless.

If clean, edit only the requested files.

After editing, test as requested, usually:

```sh
bash build.sh
```

Then verify patch contents:

```sh
git status --porcelain
git diff --name-only
```

Only intended source files may be changed. Generated/build files should normally be ignored by `.gitignore`; do not add them.

Create the patch with:

```sh
git add <intended files>
git commit -m "<subject>"
git format-patch -1 --stdout > /mnt/data/chatgpt.patch
```

Then verify:

```sh
grep '^Subject:' /mnt/data/chatgpt.patch
grep '^diff --git' /mnt/data/chatgpt.patch
```

Offer the patch link only after this verification.

### Patch acceptance/rejection

If Ron accepts the patch, do nothing special. `/mnt/data/blud` already contains the patch commit.

If Ron rejects the most recent ChatGPT patch, he may say:

```text
REVERT
```

Then run:

```sh
cd /mnt/data/blud
git reset --hard HEAD~1
rm -f /mnt/data/chatgpt.patch
git status --porcelain
```

Report the resulting HEAD and clean/dirty status.

### Hard rules

- Normal work uses `/mnt/data/blud`, not `/mnt/data/blud.zip`.
- `blud.zip` is read only by `CLOBBER.sh`.
- No candidate zip workflow.
- No accept/reject state files.
- No fresh/continue mode.
- No source patch link unless `/mnt/data/chatgpt.patch` was just generated and verified.

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
- Generated/build files should be ignored by the repo `.gitignore` rather than special patch-script cleanup.
- If `git status --porcelain` shows generated/build files before patch creation, stop and report the exact output instead of guessing.

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

`CLOBBER.sh` creates this symlink when `/mnt/data/LuaJIT-2.1` exists. Normal patch work should not recreate the worktree or read `blud.zip` to fix this.

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
