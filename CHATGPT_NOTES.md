# ChatGPT Notes for blud

These are working notes for ChatGPT sessions on Ron Burk's `blud` project. Source code and Ron's current instructions override these notes if they disagree.

## Current patch workflow

- Treat each freshly uploaded `/mnt/data/blud.zip` as the baseline for new patch work.
- Recreate `/mnt/data/blud` from the zip instead of unzipping over an old tree.
- Commit the uploaded contents as `baseline from uploaded blud.zip` before editing.
- Make one small source change at a time.
- Generate the patch as `/mnt/data/chatgpt.patch` and give Ron the sandbox link.
- Prefer deterministic helper scripts over ad hoc patch generation.
- Before providing a patch link, verify the patch subject and touched files match the requested change.

## Ron's local apply workflow

Ron applies patches with `gpatch.sh`, which reads `chatgpt.patch` and runs:

```sh
git am --no-3way chatgpt.patch
```

`--no-3way` is intentional. It makes patch failures deterministic when ChatGPT's throwaway baseline differs from Ron's real repository.

## Generated files and patch exclusions

- `build.sh` regenerates `bludlua.c`.
- Do not include generated `bludlua.c` changes in source patches.
- Restore generated files before creating a patch, usually with:

```sh
git checkout -- bludlua.c
```

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

## Current design focus

The current design discussion concerns rule/operator responsibilities, especially the `::` operator and `PREPARE_PREREQUISITES`.

Working theory:

- Hardcode built-in operators until their behavior is correct.
- Do not over-design extension points before the built-ins work.
- `BUILD_PREREQUISITES` should probably only walk already-prepared prerequisite atoms.
- Preparation logic should not be hidden inside the prerequisite build loop.

## Known issue: `::` operator

For a rule like:

```text
blud :: blud.c bludlua.c oslinux.c
```

intended behavior is roughly:

```text
blud.c     -> blud.o
bludlua.c  -> bludlua.o
oslinux.c  -> oslinux.o
blud       : blud.o bludlua.o oslinux.o
```

Current bad symptom previously seen:

```text
gcc -o debug/blud blud.c debug/bludlua.c oslinux.c -L./luajit/src -lluajit
```

This compiles/links `.c` files directly and can omit needed include flags.

## Debugger notes

- `debug.lua` was renamed to `debugger.lua` to avoid collision with Lua's standard `debug` module.
- Runtime should load it with `require("debugger")`.
- `-d` should set `debugger.probe = debugger.real_probe`.
- Interactive commands include `q`, `c`, `s`, `n`, `bt`/`where`, `e <lua>`, and `?`.

## Style preferences

- Be concise.
- Inspect current files before proposing changes.
- Prefer one minimal change at a time.
- Use 4-space indentation and snake_case.
- Avoid generic advice in code reviews; focus on likely practical problems.
