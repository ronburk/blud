# ChatGPT Notes for blud

These are concise handoff notes for future ChatGPT sessions working on Ron
Burk's `blud` project. They were refreshed on 2026-07-26 after prerequisite
globs were moved into rule evaluation.

## Start of a chat

1. Read the current Project Instructions. They are authoritative over this
   file, old chats, and remembered workflow variants.
2. Use the current GitHub `main` branch as the source of truth. Ignore uploaded
   or restored archives unless Ron explicitly directs otherwise.
3. Check `origin/main` and the status of any previously worked PR before
   starting. Merge notifications are not automatic.
4. Use a clean ordinary local clone and a separate feature branch for each
   task. Do not commit to `main`.
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

Current `main` includes the merged work through PR #29:

- structured line parsing and structured logical exits;
- `-h`, `--why`, and silent command execution;
- Linux copy primitives and the virtual-shell `cp` command;
- early installation of the embedded Lua module loader;
- private target-specific variables;
- per-test staging and nested success logs;
- a first user README;
- intelligent messages on operator assertions;
- early prerequisite-glob expansion.

There are 13 tests, `test0001` through `test0013`.

`build.sh` embeds an explicit list of Lua modules into `bludlua.c`. Any new Lua
module must be added to that list. The minimal LuaJIT headers and static library
needed by the Linux build are tracked under `luajit/src/`; `luajit.zip` and a
complete LuaJIT source tree are not required.

`runtime.lua` contains substantial obsolete commented-out implementations.
Search results there may identify dead code, so verify the active definition
and its callers before editing.

## Important current semantics

### Prerequisite glob timing

Ordinary prerequisite globs expand during `operator:EVAL_RULE()`, after macro
expansion and before the rule is stored. They enumerate existing filesystem
names only:

- virtual buildable names do not become glob matches;
- later-created files do not enter an earlier rule;
- unmatched patterns contribute nothing;
- matches are sorted within each pattern.

The base operator implements this through
`GLOB_PREREQUISITE_WORDS()`. `:TEST:` intentionally bypasses the base expansion
because its patterns are relative to the suite directory. `:BUILD:` validates
its raw prerequisite tokens before generic globbing can discard an unmatched
pattern. `test/test0013` protects these details.

### Target-specific variables

Target-specific variables apply only to the named target. Every target scope
has the fixed parent chain
`build -> commandline -> bludfile -> environment -> base`; prerequisite
traversal never inserts another target scope into that chain. Use `:BUILD:`
assignments for values that should reach an entire build configuration.

`-W` sets `.ASSUME_NEW` in the named atom's target scope, so it affects only
that atom.
`.JUST_PRINT` and `.SILENT` remain ordinary inherited command-line Booleans.

### Current explicit-rule representation

Explicit rules are still shared raw tables created by
`operator.lua:M:ADD_RULE()` and registered in `blud.rules`, initialized by
`runtime.lua`. Their directly accessed fields are:

```
targets
operator
prereq_words
action
source_rule_prepared
test_rule_prepared
```

Every current explicit rule has exactly one target. `GROUP_TARGETS()` has never
had an operator override, although the representation still carries a
one-element `targets` array.

Coupling is distributed as follows:

- `operator.lua` creates rules, enforces repeated-declaration invariants, and
  mutates special-operator state;
- `atom.lua` reads rule data and dispatches through `rule.operator`;
- `why.lua` walks `blud.rules`, `rule.targets`, and `rule.prereq_words`;
- `runtime.lua` recognizes `:BUILD:` by inspecting `rule.operator`;
- `::` and `:TEST:` use separate one-time preparation flags.

Implicit pattern rules in `implicit.lua` are a different data structure with a
different identity and lifecycle. They should not be unified with concrete
explicit rules merely because both are called rules.

Declared prerequisite names live in `rule.prereq_words`. During building they
are materialized as atoms in `atom.PREREQUISITES`; `$<` and `$^` in `scope.lua`
consume that atom list. The two representations serve different phases.

## Current design question: an explicit Rule object

The next design under consideration is to make explicit rules objects that
hide their representation. No implementation has been approved or started.

The change appears worthwhile only if the object owns invariants and behavior,
not if it merely replaces field reads with trivial getters. The proposed
boundary is:

- add `rule.lua` with private rule storage and a private registry;
- use `Rule.add()` to attach one rule to one target, accumulate repeated
  prerequisite declarations, and reject mixed operators or multiple actions;
- copy prerequisite arrays on input and output so private storage cannot be
  mutated indirectly;
- remove dormant `GROUP_TARGETS()` support and the `targets` array;
- let a rule own operator dispatch for bind, prepare, build prerequisites,
  build, and action execution;
- centralize one-time preparation, replacing `source_rule_prepared` and
  `test_rule_prepared`, with an intelligent recursive-preparation assertion;
- migrate `::`, `:TEST:`, `why.lua`, and the `:BUILD:` check to the Rule API;
- keep implicit rules separate;
- keep `atom.PREREQUISITES` on atoms in the first refactor.

Likely affected files:

```
rule.lua
build.sh
runtime.lua
operator.lua
atom.lua
why.lua
test/test0013
test/test0014
```

`test/test0014` was proposed to cover hidden fields, repeated-declaration
accumulation and order, mixed-operator rejection, second-action rejection, and
exactly-once preparation. `test/test0013` currently reads
`rule.prereq_words` directly and would need to use the public Rule API.

One unresolved implementation detail is debugging private-storage objects:
`util.dump()` does not currently provide a general custom-object protocol, and
the existing ad hoc `rule.dump` field is not honored by it. Decide whether
`rule:dump()` is sufficient or whether `util.dump()` needs a narrow extension.

Do not combine the first Rule refactor with moving `atom.PREREQUISITES` or
unifying implicit rules; either would broaden the change substantially.

## Validation

Use the smallest focused test while developing, then validate the integrated
operators and diagnostics:

```
bash build.sh
(cd test && ../blud -f test0013)
./blud
./blud -B test
./blud -f test/test0001 --why talk
git diff --check
git status --short
```

After changing Lua sources, rerun the relevant `lua-nav.awk` query before
committing.

## Do not resurrect

The following belong to retired workflows or completed work:

- `/mnt/data` archive selection, `.FRESH`, `.PATCH`, preflight leases, and
  `chatgpt_patch_finish.sh` as the normal collaboration workflow;
- `CHATGPT_PREFLIGHT.sh`;
- `lua-index.json` and its Python/tree-sitter generator;
- the private-variable implementation plan;
- the old claim that multiline actions are unimplemented;
- the paused `test0002` design as the current priority;
- `luajit.zip`.

Use GitHub branches and draft PRs under the current Project Instructions.
