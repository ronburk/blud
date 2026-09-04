# blud

*There will be blud.*

[Download the current Windows build](https://github.com/ronburk/blud/releases/download/windows-build/blud.exe).

Blud is an experimental build tool. It reads a `bludfile`, builds a
dependency graph, and runs indented actions when a target is missing or older
than one of its prerequisites.

The language borrows familiar ideas from `make`, but Blud embeds LuaJIT,
provides its own small command shell, and has operators for named build
contexts, source lists, and test suites.

Blud is under active development. This README describes the behavior that
currently exists; it is not yet a complete language reference.

## A small bludfile

Create a file named `bludfile`:

```
CC = gcc
CFLAGS = -Wall -Wextra

all: hello

hello: hello.c
    shell $(CC) $(CFLAGS) -o $@ $<
```

Then run:

```
./blud
```

With no target on the command line, Blud builds the first ordinary target in
the file, `all` in this example. You can instead name a target explicitly:

```
./blud hello
```

`hello` is rebuilt when it does not exist or when `hello.c` is newer. Action
lines are indented. Each action is printed before it runs unless silent mode is
enabled.

## Command line

```
Usage: blud [OPTION]... [TARGET]...

Options:
  -f FILE              Read FILE instead of bludfile.
  --lua FILE [ARG]...  Run FILE with embedded LuaJIT; pass remaining arguments.
  -d                    Start the interactive debugger.
  -B                    Rebuild targets regardless of timestamps.
  --why TARGET          Build normally, then explain TARGET's build decision.
  -n                    Print actions without executing them.
  -s, --silent,
      --quiet           Do not print actions before executing them.
  -W ATOM               Assume ATOM is newly changed.
  -v                    Show blud and LuaJIT versions and exit.
  -?, -h, --help        Show this help and exit.
```

For example:

```
./blud -n release
./blud -B test
./blud --why hello
./blud -f path/to/bludfile all
```

## Rules and actions

An ordinary rule has targets on the left, prerequisites on the right, and
optional indented actions:

```
output: input1 input2
    echo building $@
    shell some-program -o $@ $^
```

Blud builds prerequisites before their target. A circular dependency is an
error.

Glob patterns in prerequisite lists expand when their rule declaration
executes, after variable expansion. They enumerate existing filesystem names,
not virtual buildable names. An unmatched pattern contributes no prerequisite,
and files created later in the same invocation do not enter an earlier rule.

Blud currently implements these commands itself when they are the first word
of an action:

| Command | Supported form |
| --- | --- |
| `cd` | `cd [--] [DIRECTORY|-]` |
| `cp` | `cp [-r|-R] [--] SOURCE DESTINATION` |
| `echo` | `echo [-n] [-e|-E]... [ARG]...` |
| `mkdir` | `mkdir [-p] [--] DIRECTORY...` |
| `rm` | `rm [-f] [-r|-R] [--] PATH...` |
| `touch` | `touch [-c|--no-create] [-t [[CC]YY]MMDDhhmm[.ss]] [--] PATH...` |
| `shell` | `shell COMMAND...` |

An unrecognized first word sends the original action through the operating-
system shell. Use `shell` explicitly to force shell interpretation when the
first word names an internal command, such as `shell echo text >file`. The
built-in `cd` changes Blud's own working directory, so
its effect remains visible to later actions.

## Variables

Variables are expanded with `$(NAME)`:

```
CC ?= gcc
CFLAGS = -Wall
CFLAGS += -Wextra
```

Rules may also assign variables for one target:

```
debug: CFLAGS += -g
```

Target-specific variables apply only to the named target. Prerequisites use
their own target-specific values, or values from the selected build and outer
scopes:

```
program: CFLAGS += -fno-strict-aliasing
```

Use a `:BUILD:` rule for values that should apply throughout a build
configuration such as `debug` or `release`.

Actions have these automatic variables:

| Variable | Meaning |
| --- | --- |
| `$@` | Bound path of the target |
| `$<` | Bound path of the first prerequisite |
| `$^` | Bound paths of all prerequisites |
| `$(OWD)` | Current output directory |

## Pattern and source-list rules

`%` introduces a pattern rule:

```
%.o: %.c
    shell $(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@
```

A `::` source-list rule finds a reverse pattern rule for each source and
creates the corresponding intermediate targets:

```
program :: main.c parse.c
```

Blud currently supplies built-in rules for compiling `.c` and `.cpp` files.
Unless the `::` rule has its own action, it uses `LINK.o` or `LINK.cxx.o` to
link the generated objects.

## Build contexts

`:BUILD:` declares named output and variable contexts:

```
debug release :BUILD:
debug: CFLAGS += -g
release: CFLAGS += -O2
```

The first declared context is the default. Its name is also its default output
directory, so a target named `program` is bound as `debug/program` in the
`debug` context while source prerequisites continue to bind to their source
paths.

Macros in rule targets and prerequisites expand in the selected build context.
Declare build-specific assignments before rules that use them:

```
debug windows :BUILD:
debug: OS_SRCS = oslinux.c
windows: OS_SRCS = oswindows.c

SRCS = main.c $(OS_SRCS)
program :: $(SRCS)
```

With the declarations above:

```
./blud
./blud release
```

The first command builds the default target in `debug`; the second builds it
in `release`.

`:BUILD:` declarations currently accept neither prerequisites nor actions.

## Test suites

`:TEST:` expands test names relative to the directory named by the suite and
runs the suite action once for each match:

```
test :TEST: test[0-9][0-9][0-9][0-9]
    shell ./blud -f $<
```

`./blud test` updates one success-log target per test. In a `debug` build, a
test named `test0001` is staged below `debug/test/test0001/`, and a successful
action creates:

```
debug/test/test0001/test0001.log
```

The source test is a prerequisite of that log, so changing the source causes
the test to run again. `-B` forces every test action to run.

Test support is still evolving. The action currently receives the original
test source as `$<`; embedded test recipes and output capture are not yet
implemented.

## Building Blud

The current build script targets Linux and requires:

- `gcc` and `g++`
- `zip`
- a built LuaJIT 2.1 tree at `luajit/`, including
  `luajit/src/libluajit.a` and the LuaJIT headers

LuaJIT is not vendored in this repository. After supplying that tree, run:

```
bash build.sh
```

This produces `./blud` with its Lua modules and built-in rules embedded. A
Windows operating-system backend exists in the source tree, but the Windows
build process is not yet documented here.
