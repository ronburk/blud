# ChatGPT Notes for blud

These are concise handoff notes for future ChatGPT sessions working on Ron
Burk's `blud` project. They were refreshed on 2026-08-03 after executable
`source` actions, sourcemapped Lua diagnostics, and non-inheriting
target-specific macros were merged.

## Start of a chat

1. Read the current Project Instructions. They are authoritative over this
   file, old chats, and remembered workflow variants.
2. Use the current GitHub `main` branch as the source of truth. Ignore uploaded
   or restored archives unless Ron explicitly directs otherwise.
3. Check `origin/main` and the status of any previously worked PR before
   starting. Merge notifications are not automatic.
4. Reuse `./blud`; update clean `main` with `git pull --ff-only`, then create a
   separate feature branch. Do not commit to `main`.
5. Read `README.md` for documented user-visible behavior.
6. Use `lua-nav.awk` before reading Lua sources:

   ```
   awk -f lua-nav.awk -- function_name *.lua
   awk -f lua-nav.awk -- --regex 'pattern' *.lua
   awk -f lua-nav.awk -- --source function_name *.lua
   ```

   Rerun it after changing relevant Lua sources. `lua-index.json` is obsolete
   and must not be regenerated or used.

Show Linux commands and brief progress while working. Never fabricate,
reconstruct, normalize, or silently alter command output.

## Current baseline

At this refresh, `main` is `4361570` and includes merged PRs #60 and #61. The
important recent behavior is:

- every concrete root target reports when it is already up to date;
- `--why` distinguishes completed, skipped, interrupted, failed, and
  structurally unreached targets, including when the build raises an error;
- compiled-bludfile syntax errors and Lua runtime errors use registered source
  maps, including cached bytecode and preserved original source text;
- the virtual-shell `source` command compiles and executes action files;
- target-specific macro assignments no longer flow into prerequisites;
- the interactive debugger has an update-phase breakpoint and a bounded,
  control-character-safe value explorer.

There are 16 direct bludfile tests, `test0001` through `test0016`.

`build.sh` embeds an explicit list of Lua modules into `bludlua.c`. Any new Lua
module must be added to that list. The build expects a built LuaJIT 2.1 tree at
`luajit/`; LuaJIT itself is not vendored.

`runtime.lua` and `blud.lua` still contain substantial obsolete commented-out
implementations. Search results may identify dead code, so verify the active
definition and its callers before editing.

## Important current semantics

### Prerequisite glob timing

Ordinary prerequisite globs expand during `operator:EVAL_RULE()`, after macro
expansion and before the rule is stored. They enumerate existing filesystem
names only:

- virtual buildable names do not become glob matches;
- later-created files do not enter an earlier rule;
- unmatched patterns contribute nothing;
- matches are sorted within each pattern.

The base operator implements this through `GLOB_PREREQUISITE_WORDS()`.
`:TEST:` intentionally bypasses the base expansion because its patterns are
relative to the suite directory. `:BUILD:` validates its raw prerequisite
tokens before generic globbing can discard an unmatched pattern.
`test/test0013` protects these details.

### Target selection and root reporting

`runtime.lua:infer_targets()` turns command-line selections into the concrete
atoms that `build_targets()` calls directly. With no positional target it
selects the default target. A selected `:BUILD:` context with no following
ordinary target also selects the default target. If needed, the default build
context is prepended.

`blud.roots` contains the complete concrete list before the first build starts.
For each root, `BUILD()` returns both timestamp and `needs_building`; a false
second result prints `NAME is up to date`. This central reporting covers
ordinary, ruleless, and build-context roots.

### Target-specific macros

Target-specific macros apply only to the named target. Every target scope has
the fixed parent chain:

```
build -> commandline -> bludfile -> environment -> base
```

Prerequisite traversal never inserts another target scope into that chain.
Use `:BUILD:` assignments for values that should reach an entire build
configuration.

The old `private` and `public` target-assignment modifiers are recognized only
to report that they are obsolete. There is currently no `override` modifier,
but its possible future use has not been ruled out.

`-W` sets `.ASSUME_NEW` in the named atom's target scope, so it affects only
that atom. `.JUST_PRINT` and `.SILENT` remain inherited command-line Booleans.

### The virtual-shell `source` command

`shell.lua` implements:

```
source [--boundary STRING] [--] FILE
```

It reads FILE, compiles the selected text as a standalone blud action, and
executes the resulting function as `action(scope, 0)`. The sourced action uses
the caller's scope and its status becomes the `source` command status.

With `--boundary`, the first line containing STRING selects an input prefix.
Every enclosed line must begin with that prefix; the prefix is stripped until
the first prefixed line beginning with STRING. Newline padding preserves the
physical file line numbers in diagnostics.

Every invocation receives a unique Lua chunk name and registers its returned
sourcemap directly. Dynamic compilation uses `compile_io.close(false)` so
executing the chunk cannot replace the main bludfile's `blud.sourcemap`.
`test/test0016` covers changed contents under one filename, caller scope,
status and error propagation, boundary line numbers, and main-map preservation.

### Lua source maps and diagnostics

`init.lua` owns a Lua-source registry keyed by chunk name. Each entry retains
the exact generated text and an optional sourcemap. `compile_io.lua` stores
each compiler input once in `sourcemap.sources`; mapping entries refer to those
texts by numeric `source_index`, so duplicate filenames remain distinct. The
source table is serialized with cached bytecode.

Freshly compiled bludfiles and `source` chunks register through
`blud.load_lua_source()`. Cached bytecode instead sets
`blud.sourcemap_chunk_name` and uses the map embedded in that bytecode; its
`sources` table still contains the preserved compiler inputs.
`blud.error_handler()` resolves runtime stack frames through those paths and
displays the preserved line. Load-time syntax errors use the same location
formatter. Diagnostics do not reopen source filenames.

Remaining sourcemap work is narrow:

- `--lua` still calls `loadfile()` directly instead of registering its text;
- the generated embedded `<runtime>` chunk still uses its older loader path;
- `source_from_generated_line()`, `report_runtime_error()`, and commented call
  sites in `blud.lua` are obsolete cleanup.

### `--why`

`--why TARGET` observes the build selected by the positional arguments; it
does not add TARGET to that build. Hooks record whether a matching atom was
reached, considered, needed rebuilding, started its action, and completed it.
The report runs after normal completion or from the Lua error handler, once
only.

The subject currently matches `atom.NAME` exactly. It does not match
`BOUND_NAME`, so a request such as `--why debug/foo.o` remains unresolved when
the atom's logical name is `foo.o`.

If no matching atom was reached, `why.lua` performs a deliberately limited
structural inference over `blud.rules`, `rule.targets`, and
`rule.prereq_words`. It does not bind names, discover implicit rules, or ask
operators to prepare prerequisites. Do not present that inferred result as an
observed build event.

### Explicit-rule representation

Explicit rules remain shared raw tables created by `operator.lua:M:ADD_RULE()`
and registered in `blud.rules`. Directly accessed fields include:

```
targets
operator
prereq_words
action
source_rule_prepared
test_rule_prepared
```

Every current explicit rule has one target, although the representation still
uses a one-element `targets` array. `operator.lua`, `atom.lua`, `runtime.lua`,
and `why.lua` all inspect or mutate this representation. Implicit rules in
`implicit.lua` have a different identity and lifecycle.

An earlier explicit `Rule` object refactor was discussed but never approved or
implemented. It is not the current next task. In particular, `test0014` is no
longer available for a proposed Rule test; it now covers standalone action
compilation and sourcemap return/embedding.

## Validation and known failure

Use the smallest focused test while developing. The recent compiler,
diagnostic, and `source` paths can be checked with:

```
bash build.sh
./blud -f test/test0014
./blud -f test/test0015
./blud -f test/test0016
./blud testsource
./blud -f test/test0001 --why talk
git diff --check
git status --short
```

As of this refresh, `./blud test` stops in `test0007.luatest`: that isolated
atom harness constructs bound atoms without `SCOPE`, while
`atom:get_timestamp()` now reads `.ASSUME_NEW` through `atom.SCOPE`. The error
is `atom.lua:149: attempt to index field 'SCOPE' (a nil value)`. This predates
and is unrelated to `source`; do not claim the full suite passed until the
harness or contract is fixed.

## Installing packages in this environment (2026-09-03)

When `apt-get` fails because its `_apt` sandbox cannot change users/groups or
write `/var/cache/apt/archives`, use a writable archive cache and disable the
package sandbox user:

```
mkdir -p /tmp/xsltproc-apt-cache/partial
apt-get -o APT::Sandbox::User=root \
        -o Dir::Cache::archives=/tmp/xsltproc-apt-cache/ install -y xsltproc
```

This successfully installed `/usr/bin/xsltproc`. The package-index update also
needed `APT::Sandbox::User=root`; the archive-cache override was needed for the
package download. The install may still report harmless cleanup/log warnings
about restricted ownership changes.

## Installing MinGW privately (2026-09-04)

When the MinGW-w64 compiler was absent and normal APT installation failed
because the container blocked writes to `/var/cache/apt/archives`, download
the packages with a writable cache and disable APT's sandbox user:

```
mkdir -p /tmp/mingw-cache/partial /tmp/mingw-root
apt-get -o APT::Sandbox::User=root \
        -o Dir::Cache::archives=/tmp/mingw-cache \
        --download-only install -y gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64
for p in /tmp/mingw-cache/*.deb; do dpkg-deb -x "$p" /tmp/mingw-root; done
```

The extracted compiler works by putting `/tmp/mingw-root/usr/bin` on `PATH`.

## Do not resurrect

The following belong to retired workflows, completed work, or superseded
plans:

- `/mnt/data` archive selection, `.FRESH`, `.PATCH`, preflight leases, and
  `chatgpt_patch_finish.sh` as the normal collaboration workflow;
- `CHATGPT_PREFLIGHT.sh`;
- `lua-index.json` and its Python/tree-sitter generator;
- public/private target-specific macro inheritance;
- the preview-only `source: would execute ...` implementation;
- reopening mapped filenames or scanning generated code for `--BLUDLINE`;
- the old claim that multiline actions are unimplemented;
- the paused `test0002` design or Rule-object proposal as the current priority;
- `luajit.zip` or uploaded repository archives as authoritative source.

Use GitHub branches and draft PRs under the current Project Instructions.
