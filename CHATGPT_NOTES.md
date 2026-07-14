# ChatGPT Notes for blud

These are continuity notes for future ChatGPT sessions working on Ron Burk's
`blud` project.

## Authority and workflow safety

The current Project Instructions are authoritative. They override this file,
all previous chats, memories, and historical workflow descriptions.

`CHATGPT_PREFLIGHT.sh` is obsolete and removed. Never attempt to run it or
reconstruct its behavior.

Before filesystem work, follow the exact archive check in the current Project
Instructions. A newly uploaded `blud-upload-*.zip` is an implicit `.FRESH`.
Use the exact `.FRESH`, `.PATCH`, `.REVERT`, `.LS`, and `.RUN` procedures from
the current Project Instructions; do not substitute older variants remembered
from chats or notes.

Show commands as they are run and preserve command output exactly. Treat
`/mnt/data/blud` as disposable. If repository state is unexpected, stop and use
`.FRESH` rather than repairing history.

## Environment hazards

- Different chats may have different `/mnt/data` sandboxes even inside the same
  project.
- `/mnt/data/blud` and generated helper files may disappear between turns.
- Uploaded archives can be rematerialized or collision-renamed.
- A cleanup glob that removes names ending in `).zip` can delete a newly
  collision-renamed upload before bootstrap. Report this explicitly if it
  happens.
- Actual command execution and exit status are the only trustworthy evidence.
- Never fabricate, reconstruct, normalize, or silently reformat command output.
- Use only the uniquely named patch path printed by
  `chatgpt_patch_finish.sh`; never link `/mnt/data/chatgpt.patch`.

## Current source/build facts

- Normal work happens in `/mnt/data/blud`.
- `build.sh` regenerates ignored generated files.
- Typical validation is intentionally small while designs are changing:
  `bash build.sh` plus one or two focused behavioral checks.
- Prefer minimal, readable changes over speculative generalization.
- Use 4-space indentation and snake_case.

## Timestamp design discussed

`runtime.lua` establishes one invocation-wide logical timestamp:

```lua
blud.current_time = os.time()
```

An approved design introduces `atom:get_timestamp()` in `atom.lua` as the
single authoritative atom timestamp accessor. It should cache the filesystem
timestamp in `atom.TIMESTAMP`, while a successfully built target receives
`blud.current_time` even when no file was created.

The proposed `-W name` implementation marks the canonical atom's target scope:

```lua
atom.SCOPE:set(".ASSUME_NEW", "true")
```

`atom:get_timestamp()` interprets that value and returns
`blud.current_time`. Command-line parsing belongs in `main.lua`, marking the
resolved atoms belongs in `blud.lua` after the bludfile executes, and
`operator.lua` should contain no special `-W` logic.

## Action parsing: current implementation

The next design work is to flesh out `compile_action()` in `compiler.lua`.

Current code:

- `compile_action()` begins near line 404 of `compiler.lua`.
- It recognizes consecutive indented physical lines using
  `compile_io.is_indented_line()`.
- It currently rejects a second action line with:

```text
Multiple action lines are not supported yet
note: combine commands with && or invoke a script
```

- A single action line is:
  1. stripped of leading whitespace;
  2. read with `get_line_remainder()`;
  3. divided into literal and macro parts;
  4. converted into deferred Lua expansion code;
  5. executed later through `blud.execute(scope, ...)`;
  6. wrapped in `function(scope, status) ... end`.
- No explicit action is represented by `nil`.

Current `compile_io.is_indented_line()` is absolute:

```lua
return text:find("^[ \t]+[^ \t\n]", pos) ~= nil
```

It asks whether the physical source line starts with whitespace. That is correct
only at the outermost parser level.

## Intended action-language direction

The action language under discussion is context-sensitive by explicit line
prefix, not by globally fixed absolute columns.

At top level, an indented action defaults to shell. Nested language markers can
switch interpretation:

```text
prog: prog.o
    : test: test.o
    :     echo "I'm an action because I'm indented"
```

For the nested blud parser, removing the enclosing physical prefix `"    : "` should yield the logical input:

should yield the logical input:

```text
test: test.o
    echo "I'm an action because I'm indented"
```

Relative to that logical input:

- `test: test.o` is not indented;
- `echo ...` is indented and is the action for `test`.

Therefore nested parsing must not compare only absolute columns. The enclosing
action-language prefix belongs to the parent context and must be removed before
the nested parser classifies indentation.

The broader language direction previously discussed is:

- Top-level action text defaults to shell.
- Lua syntax enters a Lua context.
- Inside Lua, `$ ` introduces shell and `: ` introduces blud.
- Embedded blud should use the normal blud parser after its enclosing prefix is
  stripped.
- Parser syntax itself is not macro-expanded; macros provide values.
- Each maximal contiguous shell region should ideally execute as one shell
  script, preserving ordinary multi-line shell flow control.

These are design goals, not all implemented behavior.

## Likely compile_io change

Do not merely add an indentation-count argument to every caller. Prefer giving
`compile_io` a context-relative logical-line view.

Conceptually:

```text
physical line
    minus enclosing context prefix
        equals logical line seen by the current parser
```

`is_indented_line()`, `skip_white()`, `get_line_remainder()`, and any other
line-oriented parser operation must agree on the same logical beginning of line.
Changing only `is_indented_line()` would recognize nested action lines but leave
the cursor and text-reading functions consuming the wrong physical prefix.

A likely design is a parser-context stack or per-input context containing the
current line prefix/logical line origin. Avoid passing raw numeric indentation
columns, because tabs and language markers such as `: ` make physical-column
counts fragile.

## Hidden state in compile_io.lua

`compile_io.lua` currently owns substantial hidden mutable state:

Output/source-map state:

```text
pre_sourcemap
post_sourcemap
sourcemap_gap
sourcemap
next_output_ln
```

Input state:

```text
input_stack
current_input
reread
```

Each `current_input` contains:

```text
name
text
source_ln
reader
pos
eol
previous_line
```

There are two independent input cursors:

1. `current_input.pos` for token/character parsing.
2. A private `pos` captured by the line-reader closure used by `get_line()`.

They are not synchronized. `source_ln` can also be advanced by both token and
line interfaces. Any redesign of nested action parsing should avoid adding a
third unrelated cursor or line-position model.

There is no general reset function; the module appears intended for one
compilation per fresh module load.

## Recommended next discussion for compile_action

Before coding, settle these points:

1. What precisely begins and ends shell, Lua, and embedded-blud regions?
2. Does the marker prefix include the whitespace after `$` or `:`?
3. How are blank lines and comments classified inside each region?
4. How does dedentation terminate an ordinary shell action?
5. How does a Lua region remain open across lines when its visible syntax is
   incomplete?
6. What exact logical text and source location should embedded blud receive?
7. How are contiguous shell lines assembled into one invocation?
8. How are status propagation and source mapping preserved across mixed regions?

Implementation should proceed in small steps. First establish relative logical
lines in `compile_io`; then extend `compile_action()` with one minimal mixed or
multi-line case. Use only one or two focused tests while the design remains in
motion.
