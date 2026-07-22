# ChatGPT Notes for blud

These notes are a handoff for future ChatGPT sessions working on Ron Burk's
`blud` project.

## Start-of-chat checklist

1. Read the current Project Instructions first. They are authoritative and
   override this file, old chats, and remembered workflow variants.
2. Read this file for current technical context.
3. Before reading Lua source, use root-level `lua-index.json` to locate actual
   files, function names, parameters, and line ranges. It is a navigation aid,
   not authoritative source.
4. Follow the exact preflight/.FRESH/.PATCH procedures from the Project
   Instructions. `CHATGPT_PREFLIGHT.sh` is obsolete and must not be recreated.
5. Show Linux commands as they run and never fabricate, reconstruct, normalize,
   or silently alter command output.

## Preflight lease

After a successful preflight or successful `.FRESH`, obtain time with a
non-shell time tool and record a lease that expires exactly 300 seconds later.

Before later filesystem work:

- a newly attached `blud-upload-*.zip` invalidates the lease and implies
  `.FRESH`;
- observed filesystem trouble invalidates the lease;
- otherwise check current time with a non-shell time tool;
- skip preflight while the lease remains valid;
- do not rerun preflight merely because a new user turn began.

If the lease is missing, expired, or cannot be checked reliably, run the exact
preflight command.

## Repository and patch workflow

- Normal work happens in `/mnt/data/blud`.
- Treat that tree as disposable.
- If worktree, index, or ancestry is unexpected, stop and use `.FRESH`; do not
  repair Git history ad hoc.
- Stage only intended files.
- `.PATCH` requires one descriptive commit and then:
  `bash chatgpt_patch_finish.sh`.
- Link only the exact unique `/mnt/data/tmp/chatgpt-<commit>.patch` path printed
  by that script. Never link `/mnt/data/chatgpt.patch`.
- Do not provide a bare diff.

`lua-index.json` is generated on Ron's machine before `build.sh` packages the
project. Treat that uploaded index as accurate for the fresh baseline only.
It may become stale as ChatGPT edits Lua sources, so use direct source
inspection for modified files and newly added or renamed functions.

`chatgpt_patch_finish.sh` deliberately does not regenerate the index and has no
Python, tree-sitter, ctags, package-index, or network dependency. The index is
resynchronized the next time Ron runs `build.sh` and uploads a fresh project
archive.

## Current primary work: private variables

The current design task is to add a `private` attribute to variable definitions.

The user prefers using the existing macro-parts table itself as the definition
object, for example:

```lua
parts.private = true
```

No private-variable behavior has been implemented yet.

### Scope-parts invariant already established

Current active code now maintains this invariant:

> Anything stored in `scope.variables` or returned by `scope:get_parts()` is
> either `nil` or a macro-parts table.

`scope:set()` remains the normalization boundary and intentionally accepts
either a string or a parts table:

```lua
function M:set(name, value)
    local parts

    if type(value) == "string" then
        parts = { value }
    else
        assert(type(value) == "table")
        parts = value
    end

    self.variables[name] = parts
end
```

Do not require callers to wrap every literal string manually.

Current automatic variables `$<`, `$^`, and `$@` all return parts tables.
Environment lookup also returns `{ value }`.
Active `blud.Macro.expand_call()` treats `scope:get_parts()` as returning a
table or nil and no longer has a raw-string variable-definition branch.

`blud.Macro.expand_tokens()` still accepts a plain string as a general
convenience API. Do not remove that merely because scope values are now parts.

### Current scope chain

Defined in `scope.lua`:

```text
base
  -> environment
    -> bludfile
      -> commandline
        -> build
          -> target scope
```

Target scopes are initially parented to `M.build`.

During build traversal, prerequisite target scopes are reparented through the
target dependency relation. Important active locations include:

```text
atom.lua:170
operator.lua:256
operator.lua:400
```

Each sets a target scope's parent to `target_atom.PARENT.SCOPE`.

That target-to-prerequisite scope inheritance is the boundary private variables
must not cross.

### Intended private semantics

The design discussion used GNU make's target-specific `private` behavior as the
model:

- a private target-specific definition is visible while evaluating that target;
- it is not inherited by prerequisites through the target-parent scope link;
- after crossing such a parent-target boundary, lookup should skip private
  definitions but continue searching outward, so a public definition in an
  outer scope can still be found;
- ordinary lexical/non-target parent traversal should not by itself suppress
  private definitions.

A private flag on parts is not sufficient by itself. Lookup also needs to know
whether it has crossed a target-inheritance boundary. GNU make conceptually has
both a per-variable private bit and a scope-chain parent-boundary marker.

Do not blanket-treat names beginning with `.` as private. `.JUST_PRINT` is
currently intended to inherit globally, while `.ASSUME_NEW` is the motivating
example of a value that should not leak from a target to its prerequisites.

### Assignment path to inspect next

Active target-specific assignment flow:

```text
runtime.lua:225  blud.eval_target_assign_rule()
atom.lua:7       target:set_variable()
runtime.lua:1072 blud.macro_assign_parts()
scope.lua:45     scope:set()
```

`blud.macro_assign_parts()` deep-copies parts, implements `?=`, `=`, `+=`,
rewrites self-references, and finally calls `scope:set()`.

Before implementing privacy, decide and test how the attribute behaves under:

- replacement with `=`;
- no-op `?=`;
- concatenation with `+=`;
- self-reference preservation;
- copying through `util.deep_copy()`.

The user previously observed that GNU make does not retain simultaneous public
and private definitions of the same variable in the same target scope; the
later definition's value/privacy wins. Do not assume more complex parallel
bindings are required unless the design changes.

### Direct scope-table operations

Most variable writes go through `scope:set()`. Important whole-table operations
that intentionally bypass it are:

```text
runtime.lua:865
    resets blud.Scope.build.variables

operator.lua:642
    aliases blud.Scope.build.variables = target.SCOPE.variables
```

Embedding metadata in each parts table naturally survives these whole-table
operations.

There are direct reads in `operator.lua` for `SWD` and `OWD`; inspect them when
changing representation or lookup behavior.

## Current command-line variable flags

Command-line flags are being unified through scope variables.

### `-n`

Parsed in `main.lua` by setting:

```lua
options.commandline_booleans[".JUST_PRINT"] = true
```

It is a textual boolean scope variable and is intentionally inherited by
actions.

### `-W atom`

Parsed in:

```text
main.lua:60-67
```

Applied after bludfile execution in:

```text
blud.lua:552-556
```

by:

```lua
atom.SCOPE:set_boolean(".ASSUME_NEW", true)
```

Consumed in:

```text
atom.lua:146-155
```

where `atom:get_timestamp()` substitutes `blud.current_time`.

The current problem is that a variable placed in a target scope can inherit into
prerequisite target scopes. Private-variable support is intended to solve that
kind of leakage cleanly.

### `-B`

`main.lua` currently parses `-B` into `options.always_make`. Verify its current
downstream behavior before changing it.

## Timestamp design

`runtime.lua` captures one invocation-wide logical timestamp:

```lua
blud.current_time = os.time()
```

`atom:get_timestamp()` in `atom.lua` is the authoritative atom timestamp
accessor. It caches the filesystem timestamp in `atom.TIMESTAMP`, except that
`.ASSUME_NEW` makes it use `blud.current_time`.

Successful actions should leave the target with the invocation timestamp even
when no file was created. Check current operator behavior before modifying this
area.

## Action parsing: current state

Multiline action blocks are implemented.

`compiler.lua:275` defines `compile_action()`.

Current behavior:

- the first indented action line establishes a strip prefix;
- `compile_io.push_strip_prefix()` makes subsequent physical lines relative to
  that prefix;
- lines are consumed until `STRIP_END`;
- each nonblank physical action line becomes a separate guarded
  `blud.execute(scope, ...)`;
- execution stops on the first nonzero status;
- no action is represented by `nil`.

This fixed the old single-action-line limitation and made tab indentation work.

It does **not** yet implement the broader mixed Lua/shell/embedded-blud action
language previously discussed. Do not restore the old notes claiming multiline
actions are still unimplemented.

## Paused test-target work

A separate unfinished design concerns:

```text
./blud test0002
```

Desired behavior was to run only that test, where `test0002` binds to
`./test/test0002`.

The broader idea was:

- when a command-line operand names a source atom with no action;
- and that atom was explicitly requested;
- reverse-resolve concrete targets that depend on it;
- build those dependents, treating the source as assumed-new for this
  invocation.

This was paused while fixing variable inheritance/private semantics. Resume it
only after the private-variable work unless the user redirects priorities.

## Useful current source locations

### Environment variables

Process environment variables are read lazily in:

```text
scope.lua:77-83
```

through `os.getenv(name)`. Blud does not copy all environment variables into a
scope and does not currently call `setenv()`.

### C `stat()` calls

Only two literal source calls were found:

```text
blud.c:418
    get_high_res_timestamp()

oslinux.c:18
    dir_exists()
```

Generated `bludlua.c` was excluded from that search.

### `blud.Macro.expand_tokens()` callers

Active calls currently include:

```text
scope.lua:23
compiler.lua:344       commented-out target-assignment code; not active
runtime.lua:229
runtime.lua:271
runtime.lua:272
runtime.lua:660
runtime.lua:674
runtime.lua:706
```

`atom.lua:110` is dead because the containing function is immediately
overwritten.
`runtime.lua:577` is inside obsolete commented-out scope code.

The active definition is at `runtime.lua:679`.

### LuaJIT headers actually used by the current C build

The compiler dependency scan showed:

```text
luajit/src/lua.h
luajit/src/luaconf.h
luajit/src/lauxlib.h
luajit/src/lualib.h
```

`lua.hpp` appears in old C++ wrapper sources but is not part of either current
build path.

## Source archaeology cautions

`runtime.lua` still contains substantial obsolete commented-out implementations,
including an old scope implementation and old phase parser. Do not edit those
merely because searches find similar function names.

Use `lua-index.json`, then verify surrounding source and whether code is active.

## Validation style

Prefer focused validation while designs are changing:

```sh
bash build.sh
```

plus targeted tests for the behavior changed.

Before committing:

```sh
bash -n <changed-shell-script>       # when applicable
git diff --check
git status --short
```

For private-variable work, add focused tests that distinguish:

1. visibility on the target itself;
2. non-inheritance into prerequisites;
3. fallback to an outer public definition after a private definition is skipped;
4. ordinary public target-specific inheritance remaining unchanged;
5. `.JUST_PRINT` continuing to inherit;
6. `.ASSUME_NEW` no longer leaking when marked private.

Keep changes small and behavior-preserving except for the explicitly introduced
private semantics.
