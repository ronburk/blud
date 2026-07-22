--[[
get_line() is the structural line reader shared by parsers nested inside one
another. It removes the structural prefix belonging to the surrounding
parsers, returns the remaining virtual line, and reports at most one stack
event:

    PUSH        enter an action-indentation boundary
    PUSHCOLON   enter a ": " directive boundary
    POP         leave one boundary
    nil         no boundary changed

Only two things are structural prefixes:

    1. indentation accepted immediately after a dependency line;
    2. zero or more spaces or tabs followed by the directive marker ": ".

Other indentation belongs to the source language and remains in the virtual
line.

Here is a complete visual example. Dots in the diagrams stand for spaces; they
are not characters in the input.

    physical source
    ----------------------------------------------------------------
    prog: prog.o
    ....if true then
    ........: foo: foo.o
    ........: ....echo 'foo'
    ....end

At the nested echo, the active prefix stack contains three exact strings:

    action indentation        "...."
    directive boundary        "....: "
    nested action indentation "...."
                               ---------
    complete prefix           "........: ...."

Therefore:

    physical  "........: ....echo 'foo'"
    prefix    "........: ...."
    virtual                 "echo 'foo'"

The corresponding calls look like this:

    returned virtual line   event       active complete prefix afterward
    ---------------------------------------------------------------------
    "prog: prog.o"          nil         ""
    "if true then"          PUSH        "...."
    "foo: foo.o"            PUSHCOLON   "........: "
    "echo 'foo'"            PUSH        "........: ...."

The indentation before a directive and the directive marker are separate
boundaries. Consequently this source:

    prog: prog.o
    ....: foo: foo.o

is exposed in two calls after the dependency:

    nil                     PUSH
    "foo: foo.o"            PUSHCOLON

The first call records the four-space action indentation. The second consumes
the ": " marker. A single physical line can therefore generate more than one
stack event.

Unwinding works the same way in reverse. Suppose the active complete prefix is:

    "........: ...."

and the next physical line is an outer action line:

    "....echo 'building prog'"

The line inherits only the first four-space entry, so get_line() retains the
analyzed line and returns one POP per call:

    "echo 'building prog'"   POP     complete prefix is now "........: "
    "echo 'building prog'"   POP     complete prefix is now "...."

The final POP carries the exposed line to the parser at that level. Earlier
POPs merely announce boundaries that must be left before that parser can use
the line.

Prefixes are stored and compared as exact text, not as indentation columns.
Spaces, tabs, and colon markers are distinct. When a physical line has one or
more leading directive markers, each colon must remain in the same character
position as the corresponding colon in the active prefix, through the length
of the shorter structural prefix.

For example, these prefixes align:

    ruler    12345678
    active   ..:...:.
    new      ..:...:.

A shorter prefix may unwind when its visible part still agrees:

    ruler    12345678
    active   ..:...:.
    new      ..:.

But shifting the second colon is an error:

    ruler    12345678
    active   ..:...:.
    new      ..:.:.
                ^
                active prefix has a space here, not a colon

Plain leading whitespace has no structural meaning unless after_dependency is
true and get_line() accepts it as action indentation. It may therefore expose
ordinary source text at an outer parser level instead of producing an
alignment error. A newly exposed root ": " marker is also allowed: the old
boundaries are popped first, then the same retained line produces PUSHCOLON.

Blank physical lines and virtual lines are skipped internally.
after_dependency remains in effect while blanks are skipped, so an action may
follow its dependency after intervening blank lines.

At EOF, get_line() returns one POP per active prefix entry. Once the stack is
empty it returns "", nil. The supplied line reader must continue returning nil
after its first EOF.
]]--

local PUSH      = "PUSH"
local PUSHCOLON = "PUSHCOLON"
local POP       = "POP"
local ERROR     = "ERROR"

local active_prefixes = {}
-- An analyzed line is retained only when it must produce more than one
-- structural event across successive get_line() calls.
local pending_line

local function reset_get_line_state()
    active_prefixes = {}
    pending_line = nil
end

-- Strip complete active-prefix entries until the first mismatch. The returned
-- depth identifies the inherited leading portion of active_prefixes; this
-- function does not modify the stack.
local function strip_active_prefixes(line)
    local virtual_line = line

    for i = 1, #active_prefixes do
        local prefix = active_prefixes[i]

        if virtual_line:sub(1, #prefix) ~= prefix then
            return virtual_line, i - 1
        end

        virtual_line = virtual_line:sub(#prefix + 1)
    end

    return virtual_line, #active_prefixes
end

-- Match the whole line against zero or more spaces and tabs.
local function is_whitespace_only(line)
    return line:match("^[ \t]*$") ~= nil
end

-- Split a directive-switch prefix from its body. Whitespace before ": " is
-- part of this single structural prefix unless dependency indentation has
-- already been established separately.
local function split_directive_prefix(line)
    return line:match("^([ \t]*: )(.*)$")
end

-- Capture only syntax already recognizable as structural on this physical
-- line. Whitespace is included when it positions a ": " directive marker;
-- otherwise it remains source-language content until after_dependency accepts
-- it as action indentation.
local function leading_structural_prefix(line)
    local prefix = ""
    local remainder = line

    while true do
        local directive_prefix, directive_body =
            split_directive_prefix(remainder)

        if directive_prefix == nil then
            return prefix
        end

        prefix = prefix .. directive_prefix
        remainder = directive_body
    end
end

-- Before stripping or changing the active stack, require the old and new
-- structural prefixes to agree through the shorter prefix. A shorter matching
-- prefix is an unwind; a longer matching prefix may introduce deeper content.
local function validate_line_prefix(line)
    local directive_prefix = split_directive_prefix(line)

    if #active_prefixes == 0 or directive_prefix == ": " then
        return
    end

    local active_prefix = table.concat(active_prefixes)
    local line_prefix = leading_structural_prefix(line)
    local common_length = math.min(#line_prefix, #active_prefix)

    if line_prefix:sub(1, common_length)
            ~= active_prefix:sub(1, common_length) then
        local shown_line_prefix = line_prefix:gsub("\t", "\\t")
        local shown_active_prefix = active_prefix:gsub("\t", "\\t")

        error(('indentation prefix "%s" does not align with active prefix "%s"')
              :format(shown_line_prefix, shown_active_prefix), 0)
    end
end

-- If a dependency is followed by an indented line, establish exactly one
-- action boundary. When the indented content begins with a directive marker,
-- retain that content so the next get_line() call can establish the directive
-- boundary separately.
local function start_indented_block_after_dependency(virtual_line)
    local indentation, indented_line =
        virtual_line:match("^([ \t]+)(.*)$")

    if not indentation then
        return nil
    end

    local directive_body = indented_line:match("^: (.*)$")

    if directive_body == nil then
        table.insert(active_prefixes, indentation)
        return indented_line, PUSH
    end

    if not is_whitespace_only(directive_body) then
        table.insert(active_prefixes, indentation)
        return nil, PUSH, {
            virtual_line = indented_line,
            inherited_depth = #active_prefixes,
        }
    end

    return nil
end

-- after_dependency reports what the caller parsed from the preceding returned
-- line. It is intentionally retained while this function skips blank input.
local function get_line(after_dependency, line_reader)
    -- With no format argument, io.read() reads one line.
    line_reader = line_reader or io.read

    while true do
        local line = pending_line
        pending_line = nil

        if line == nil then
            local physical_line = line_reader()

            if physical_line == nil then
                if #active_prefixes == 0 then
                    return "", nil
                end

                table.remove(active_prefixes)
                return "", POP
            end

            if not is_whitespace_only(physical_line) then
                validate_line_prefix(physical_line)

                local virtual_line, inherited_depth =
                    strip_active_prefixes(physical_line)

                line = {
                    virtual_line = virtual_line,
                    inherited_depth = inherited_depth,
                }
            end
        end

        if line ~= nil then
            if #active_prefixes > line.inherited_depth then
                table.remove(active_prefixes)

                -- Retain the analyzed line for another POP, or so a newly
                -- exposed directive prefix can produce PUSHCOLON next time.
                if #active_prefixes > line.inherited_depth
                        or split_directive_prefix(line.virtual_line) then
                    pending_line = line
                end

                return line.virtual_line, POP
            end

            local virtual_line = line.virtual_line

            if not is_whitespace_only(virtual_line) then
                if after_dependency then
                    local returned_line, stack_event, replay_line =
                        start_indented_block_after_dependency(virtual_line)

                    if stack_event ~= nil then
                        pending_line = replay_line
                        return returned_line, stack_event
                    end
                end

                local directive_prefix, directive_body =
                    split_directive_prefix(virtual_line)

                if not directive_prefix then
                    return virtual_line, nil
                end

                if not is_whitespace_only(directive_body) then
                    -- Without a preceding dependency, the whitespace and
                    -- colon marker form one directive-switch boundary.
                    table.insert(active_prefixes, directive_prefix)
                    return directive_body, PUSHCOLON
                end
            end
        end
    end
end

local tests = {
    -- Push a simple action indent and pop it at EOF.
    { name="test0001", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",         nil
    echo 'simple action'    | true  =>[1] "echo 'simple action'", PUSH
EOF                         | false =>[0] "",                     POP
]]},
    -- Enter a directive from indented Lua and return to the action.
    { name="test0002", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",     nil
    if true then            | true  =>[1] "if true then",     PUSH
        : foo: foo.o        | false =>[2] "foo: foo.o",       PUSHCOLON
    end                     | true  =>[1] "end",              POP
EOF                         | false  =>[0] "",                 POP
]]},
    -- Expose action and directive pushes separately, then unwind at EOF.
    { name="test0003", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",     nil
    : foo: foo.o            | true  =>[1] nil,                   PUSH
|                             false =>[2] "foo: foo.o",       PUSHCOLON
    :     echo 'foo'        | true  =>[3] "echo 'foo'",       PUSH
EOF                         | false =>[2] "",                 POP
EOF                         | false =>[1] "",                 POP
EOF                         | false =>[0] "",                 POP
]]},

    -- Pop nested directive levels before resuming an outer action.
    { name="test0004", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",         nil
    : foo: foo.o            | true  =>[1] nil,                   PUSH
|                             false =>[2] "foo: foo.o",       PUSHCOLON
    :     echo 'foo'        | true  =>[3] "echo 'foo'",           PUSH
    echo 'building prog'    | false =>[2] "echo 'building prog'", POP
|                             false =>[1] "echo 'building prog'", POP
EOF                         | false =>[0] "",                     POP
]]},
    -- End an action when a new top-level dependency appears.
    { name="test0005", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",         nil
    echo 'building prog'    | true  =>[1] "echo 'building prog'", PUSH
next: next.o                | false =>[0] "next: next.o",         POP
EOF                         | true  =>[0] "",                     nil
]]},
    -- Preserve unmatched leading whitespace after an action pop.
    { name="test0006", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",         nil
    echo 'building prog'    | true  =>[1] "echo 'building prog'", PUSH
  next: next.o              | false =>[0] "  next: next.o",       POP
EOF                         | false =>[0] "",                     nil
]]},
    -- Recognize only colon-plus-space as a directive prefix.
    { name="test0007", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",          nil
    if true then            | true  =>[1] "if true then",          PUSH
        :not_a_directive()  | false =>[1] "    :not_a_directive()", nil
        : foo: foo.o        | false =>[2] "foo: foo.o",            PUSHCOLON
    end                     | true  =>[1] "end",                   POP
EOF                         | false =>[0] "",                      POP
]]},
    -- Resume an outer action after repeated pops.
    { name="test0008", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",          nil
    : foo: foo.o            | true  =>[1] nil,                   PUSH
|                             false =>[2] "foo: foo.o",       PUSHCOLON
    :     echo 'foo'        | true  =>[3] "echo 'foo'",            PUSH
    echo 'building prog'    | false =>[2] "echo 'building prog'",  POP
|                             false =>[1] "echo 'building prog'",  POP
    echo 'still prog'       | false =>[1] "echo 'still prog'",     nil
EOF                         | false =>[0] "",                      POP
]]},
    -- Unwind a dependency nested inside another directive.
    { name="test0009", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",          nil
    : foo: foo.o            | true  =>[1] nil,                   PUSH
|                             false =>[2] "foo: foo.o",       PUSHCOLON
    :     : bar: bar.o      | true  =>[3] nil,                   PUSH
|                             false =>[4] "bar: bar.o",       PUSHCOLON
    echo 'building prog'    | true  =>[3] "echo 'building prog'",  POP
|                             false =>[2] "echo 'building prog'",  POP
|                             false =>[1] "echo 'building prog'",  POP
EOF                         | false =>[0] "",                      POP
]]},
    -- Attach an action to the second of consecutive dependencies.
    { name="test0010", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",          nil
next: next.o                | true  =>[0] "next: next.o",          nil
    echo 'building next'    | true  =>[1] "echo 'building next'",  PUSH
EOF                         | false =>[0] "",                      POP
]]},
    -- Return from a directive action to surrounding Lua.
    { name="test0011", text=[[
if true then                | false =>[0] "if true then",          nil
    : foo: foo.o            | false =>[1] "foo: foo.o",            PUSHCOLON
    :     echo 'foo'        | true  =>[2] "echo 'foo'",            PUSH
end                         | false =>[1] "end",                   POP
|                             false =>[0] "end",                   POP
EOF                         | false =>[0] "",                      nil
]]},
    -- Skip empty and colon-only physical lines before an action.
    { name="test0012", text=[[
prog: prog.o                | false =>[0] "prog: prog.o", nil
    : foo: foo.o            | true  =>[1] nil,                   PUSH
|                             false =>[2] "foo: foo.o",       PUSHCOLON
|
    : |
    :     echo 'foo'        | true  =>[3] "echo 'foo'",   PUSH
EOF                         | false =>[2] "",             POP
EOF                         | false =>[1] "",             POP
EOF                         | false =>[0] "",             POP
]]},
    -- Pop at EOF after empty, whitespace-only, and colon-only lines.
    { name="test0013", text=[[
prog: prog.o                | false =>[0] "prog: prog.o", nil
    echo 'prog'             | true  =>[1] "echo 'prog'",  PUSH
|
   |
    : |
EOF                         | false =>[0] "",             POP
]]},
    -- Handle a top-level colon directive and its action.
    { name="test0014", text=[[
: foo: foo.o                | false =>[1] "foo: foo.o",       PUSHCOLON
:     echo 'foo'            | true  =>[2] "echo 'foo'",       PUSH
EOF                         | false =>[1] "",                 POP
EOF                         | false =>[0] "",                 POP
]]},
    -- Use a two-space action indentation prefix.
    { name="test0015", text=[[
prog: prog.o                | false =>[0] "prog: prog.o", nil
  echo 'one'                | true  =>[1] "echo 'one'",  PUSH
  echo 'two'                | false =>[1] "echo 'two'",  nil
EOF                         | false =>[0] "",            POP
]]},
    -- Skip blank physical lines before the first action.
    { name="test0016", text=[[
prog: prog.o                | false =>[0] "prog: prog.o", nil
|
   |
    echo 'building prog'    | true  =>[1] "echo 'building prog'", PUSH
EOF                         | false =>[0] "",             POP
]]},
    -- Keep Lua indentation as content under a colon prefix.
    { name="test0017", text=[[
: if true then              | false =>[1] "if true then",       PUSHCOLON
:     print('true')         | false =>[1] "    print('true')",  nil
: end                       | false =>[1] "end",                nil
EOF                         | false =>[0] "",                   POP
]]},
    -- Handle unequal space widths in nested structural prefixes.
    { name="test0018", text=[[
prog: prog.o                | false =>[0] "prog: prog.o", nil
  : foo: foo.o              | true  =>[1] nil,                   PUSH
|                             false =>[2] "foo: foo.o",       PUSHCOLON
  :   echo 'foo'            | true  =>[3] "echo 'foo'",   PUSH
EOF                         | false =>[2] "",             POP
EOF                         | false =>[1] "",             POP
EOF                         | false =>[0] "",             POP
]]},
    -- Reject a colon shifted left across nested action/directive prefixes.
    { name="test0019", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",       nil
    if true then            | true  =>[1] "if true then",       PUSH
        : foo: foo.o        | false =>[2] "foo: foo.o",         PUSHCOLON
        :     echo 'foo'    | true  =>[3] "echo 'foo'",         PUSH
    : bar: bar.o            | false =>[3] "indentation prefix \"    : \" does not align with active prefix \"        :     \"", ERROR
]]},
    -- Build multiple nested indentation-and-colon prefix levels.
    { name="test0020", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",       nil
    : prog: oslinux.o       | true  =>[1] nil,                   PUSH
|                             false =>[2] "prog: oslinux.o",       PUSHCOLON
    :     : CFLAGS += -g    | true  =>[3] nil,                   PUSH
|                             false =>[4] "CFLAGS += -g",       PUSHCOLON
EOF                         | false =>[3] "",                   POP
EOF                         | false =>[2] "",                   POP
EOF                         | false =>[1] "",                   POP
EOF                         | false =>[0] "",                   POP
]]},
    -- Nest a colon-only directive prefix at the same indentation.
    { name="test0021", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",       nil
    : prog: oslinux.o       | true  =>[1] nil,                   PUSH
|                             false =>[2] "prog: oslinux.o",       PUSHCOLON
    : : CFLAGS += -g        | true  =>[3] "CFLAGS += -g",       PUSHCOLON
EOF                         | false =>[2] "",                   POP
EOF                         | false =>[1] "",                   POP
EOF                         | false =>[0] "",                   POP
]]},
    -- Return from a nested assignment to a sibling dependency.
    { name="test0022", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",       nil
    : foo: foo.o            | true  =>[1] nil,                   PUSH
|                             false =>[2] "foo: foo.o",       PUSHCOLON
    :     : CFLAGS += -g    | true  =>[3] nil,                   PUSH
|                             false =>[4] "CFLAGS += -g",       PUSHCOLON
    : bar: bar.o            | false =>[3] "bar: bar.o",         POP
|                             false =>[2] "bar: bar.o",         POP
EOF                         | true  =>[1] "",                   POP
EOF                         | false =>[0] "",                   POP
]]},
    -- Replay a top-level colon directive after an action pop.
    { name="test0023", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",       nil
    echo 'prog'             | true  =>[1] "echo 'prog'",        PUSH
: foo: foo.o                | false =>[0] ": foo: foo.o",       POP
|                             false =>[1] "foo: foo.o",         PUSHCOLON
EOF                         | true  =>[0] "",                   POP
]]},
    -- Reject a colon shifted right while unwinding to Lua.
    { name="test0024", text=[[
if true then                | false =>[0] "if true then",       nil
    : prog: prog.o          | false =>[1] "prog: prog.o",       PUSHCOLON
    :     echo 'prog'       | true  =>[2] "echo 'prog'",        PUSH
      : foo: foo.o          | false =>[2] "indentation prefix \"      : \" does not align with active prefix \"    :     \"", ERROR
]]},
    -- Ignore a blank line before a multi-level action unwind.
    { name="test0025", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",         nil
    : foo: foo.o            | true  =>[1] nil,                   PUSH
|                             false =>[2] "foo: foo.o",       PUSHCOLON
    :     echo 'foo'        | true  =>[3] "echo 'foo'",           PUSH
                            |
    echo 'building prog'    | false =>[2] "echo 'building prog'", POP
|                             false =>[1] "echo 'building prog'", POP
EOF                         | false =>[0] "",                     POP
]]},
    -- Treat arbitrary Lua indentation as non-structural content.
    { name="test0026", text=[[
if true then                | false =>[0] "if true then",        nil
    print("four")           | false =>[0] "    print(\"four\")", nil
  print("two")              | false =>[0] "  print(\"two\")",    nil
end                         | false =>[0] "end",                  nil
]]},
    -- Treat a colon without following space as action text.
    { name="test0027", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",       nil
    :not_a_directive()      | true  =>[1] ":not_a_directive()", PUSH
EOF                         | false =>[0] "",                   POP
]]},
    -- Resume a sibling directive under a combined prefix.
    { name="test0028", text=[[
if true then                | false =>[0] "if true then",       nil
  : foo: foo.o              | false =>[1] "foo: foo.o",         PUSHCOLON
  :     echo 'foo'          | true  =>[2] "echo 'foo'",         PUSH
  : bar: bar.o              | false =>[1] "bar: bar.o",         POP
EOF                         | true  =>[0] "",                   POP
]]},
    -- Pop on a line consisting only of the active colon prefix.
    { name="test0029", text=[[
if true then                | false =>[0] "if true then",       nil
  : foo: foo.o              | false =>[1] "foo: foo.o",         PUSHCOLON
  :     echo 'foo'          | true  =>[2] "echo 'foo'",         PUSH
  : |                         false =>[1] "",                   POP
EOF                         | false =>[0] "",                   POP
]]},
    -- Reject a colon marker shifted left while unwinding nested prefixes.
    { name="test0030", text=[[
if true then                | false =>[0] "if true then",       nil
    : prog: prog.o          | false =>[1] "prog: prog.o",       PUSHCOLON
    :     echo 'prog'       | true  =>[2] "echo 'prog'",        PUSH
  : foo: foo.o              | false =>[2] "indentation prefix \"  : \" does not align with active prefix \"    :     \"", ERROR
]]},
    -- Reject a shifted colon marker even when the line has no directive text.
    { name="test0031", text=[[
if true then                | false =>[0] "if true then",       nil
    : prog: prog.o          | false =>[1] "prog: prog.o",       PUSHCOLON
    :     echo 'prog'       | true  =>[2] "echo 'prog'",        PUSH
  : |                         false =>[2] "indentation prefix \"  : \" does not align with active prefix \"    :     \"", ERROR
]]},
    -- A dependency need not have an action; ordinary indentation may unwind.
    { name="test0032", text=[[
if true then                | false =>[0] "if true then",       nil
  : foo: foo.o              | false =>[1] "foo: foo.o",         PUSHCOLON
   print("not an action")   | true  =>[0] "   print(\"not an action\")", POP
EOF                         | false =>[0] "",                    nil
]]},
    -- Reject a shifted inner colon after the outer marker still aligns.
    { name="test0033", text=[[
if true then                | false =>[0] "if true then",       nil
  : foo: foo.o              | false =>[1] "foo: foo.o",         PUSHCOLON
  :   : CFLAGS += -g        | true  =>[2] nil,                   PUSH
|                             false =>[3] "CFLAGS += -g",       PUSHCOLON
  : : CXXFLAGS += -g        | false =>[3] "indentation prefix \"  : : \" does not align with active prefix \"  :   : \"", ERROR
]]},
    -- Replay a nonstructural indented line through a complete nested unwind.
    { name="test0034", text=[[
if true then                | false =>[0] "if true then",       nil
  : foo: foo.o              | false =>[1] "foo: foo.o",         PUSHCOLON
  :   : CFLAGS += -g        | true  =>[2] nil,                   PUSH
|                             false =>[3] "CFLAGS += -g",       PUSHCOLON
   print("outer")           | false =>[2] "   print(\"outer\")", POP
|                             false =>[1] "   print(\"outer\")", POP
|                             false =>[0] "   print(\"outer\")", POP
EOF                         | false =>[0] "",                    nil
]]},
    -- Grow nested directive prefixes without dependency action indentation.
    { name="test0035", text=[[
  : CFLAGS += -g            | false =>[1] "CFLAGS += -g",       PUSHCOLON
  : : CXXFLAGS += -g        | false =>[2] "CXXFLAGS += -g",     PUSHCOLON
  : : : LDFLAGS += -s       | false =>[3] "LDFLAGS += -s",      PUSHCOLON
EOF                         | false =>[2] "",                    POP
EOF                         | false =>[1] "",                    POP
EOF                         | false =>[0] "",                    POP
]]},
    -- Replay a root directive through several active nested boundaries.
    { name="test0036", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",       nil
  : foo: foo.o              | true  =>[1] nil,                   PUSH
|                             false =>[2] "foo: foo.o",       PUSHCOLON
  :   echo 'foo'            | true  =>[3] "echo 'foo'",         PUSH
: bar: bar.o                | false =>[2] ": bar: bar.o",       POP
|                             false =>[1] ": bar: bar.o",       POP
|                             false =>[0] ": bar: bar.o",       POP
|                             false =>[1] "bar: bar.o",         PUSHCOLON
EOF                         | true  =>[0] "",                   POP
]]},
    -- Preserve after_dependency across an aligned nested colon-only line.
    { name="test0037", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",       nil
  : foo: foo.o              | true  =>[1] nil,                   PUSH
|                             false =>[2] "foo: foo.o",       PUSHCOLON
  : : bar: bar.o            | true  =>[3] "bar: bar.o",         PUSHCOLON
  : : |
  : :   echo 'bar'          | true  =>[4] "echo 'bar'",         PUSH
EOF                         | false =>[3] "",                   POP
EOF                         | false =>[2] "",                   POP
EOF                         | false =>[1] "",                   POP
EOF                         | false =>[0] "",                   POP
]]},
    -- Reject a shifted directive marker beneath plain action indentation.
    { name="test0038", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",       nil
    echo 'prog'             | true  =>[1] "echo 'prog'",        PUSH
  : foo: foo.o              | false =>[1] "indentation prefix \"  : \" does not align with active prefix \"    \"", ERROR
]]},
    -- A colon without following space is content and unwinds a directive.
    { name="test0039", text=[[
: foo: foo.o                | false =>[1] "foo: foo.o",         PUSHCOLON
:not_a_directive()          | false =>[0] ":not_a_directive()", POP
EOF                         | false =>[0] "",                    nil
]]},
    -- Replay a root colon-only line through several active boundaries.
    { name="test0040", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",       nil
  : foo: foo.o              | true  =>[1] nil,                   PUSH
|                             false =>[2] "foo: foo.o",       PUSHCOLON
  :   echo 'foo'            | true  =>[3] "echo 'foo'",         PUSH
: |                           false =>[2] ": ",                  POP
|                             false =>[1] ": ",                  POP
|                             false =>[0] ": ",                  POP
EOF                         | false =>[0] "",                    nil
]]},
    -- Strip exactly one delimiter space after a directive colon.
    { name="test0041", text=[[
:  print("x")               | false =>[1] " print(\"x\")",      PUSHCOLON
EOF                         | false =>[0] "",                    POP
]]},
    -- A root directive after a dependency is not action indentation.
    { name="test0042", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",       nil
: foo: foo.o                | true  =>[1] "foo: foo.o",         PUSHCOLON
EOF                         | true  =>[0] "",                    POP
]]},

}

do
local change_value = {
    PUSH      = PUSH,
    PUSHCOLON = PUSHCOLON,
    POP       = POP,
    ERROR     = ERROR,
}

local function fail(test, row, message, ...)
    error(("%s:%d: " .. message):format(test, row, ...), 0)
end

local function parse_row(test, row, text)
    local input, expected = text:match("^(.-)|(.*)$")
    if not input then
        fail(test, row, "missing |")
    end

    if not expected:match("%S") then
        local value

        if input:match("^EOF[ \t]*$") then
            value = false
        elseif input:match("^EMPTY[ \t]*$") then
            value = ""
        else
            value = input
        end

        return {
            input_only = true,
            value = value,
        }
    end

    expected = expected:match("^%s*(.-)%s*$")

    local dependency, depth, result =
        expected:match("^([%a]+)%s*=>%[(%d+)%]%s*(.-)%s*$")

    if dependency ~= "true" and dependency ~= "false" then
        fail(test, row, "expected true or false")
    end

    local literal, change_name =
        result:match("^(.*),%s*([%a]+)%s*$")

    if not literal then
        fail(test, row, "bad expected result")
    end

    local loader, message = loadstring("return " .. literal)
    if not loader then
        fail(test, row, "%s", message)
    end

    local inputs
    if input == "" then
        inputs = {}
    elseif input:match("^EOF[ \t]*$") then
        inputs = { false }
    elseif input:match("^EMPTY[ \t]*$") then
        inputs = { "" }
    else
        inputs = { input }
    end

    local change
    if change_name ~= "nil" then
        change = change_value[change_name]
        if change == nil then
            fail(test, row, "unknown change %q", change_name)
        end
    end

    return {
        input = input,
        inputs = inputs,
        dependency = dependency == "true",
        depth = tonumber(depth),
        line = loader(),
        change = change,
        change_name = change_name,
    }
end

local function run_get_line_tests(tests)
    for _, test in ipairs(tests) do
        reset_get_line_state()
        local row = 0
        local ended_with_error = false
        local pending_inputs = {}

        for text in (test.text .. "\n"):gmatch("(.-)\n") do
            if text:match("%S") then
                row = row + 1
                local expected = parse_row(test.name, row, text)

                if expected.input_only then
                    pending_inputs[#pending_inputs + 1] = expected.value
                else
                    for _, input in ipairs(expected.inputs) do
                        pending_inputs[#pending_inputs + 1] = input
                    end

                    expected.inputs = pending_inputs
                    pending_inputs = {}

                    local reads = 0

                    local function reader()
                        reads = reads + 1

                        if #expected.inputs == 0 then
                            fail(test.name, row,
                                 "get_line unexpectedly read input")
                        end
                        if reads > #expected.inputs then
                            fail(test.name, row,
                                 "get_line read input more than %d times",
                                 #expected.inputs)
                        end

                        local input = expected.inputs[reads]
                        if input == false then
                            return nil
                        end
                        return input
                    end

                    local ok, line, change =
                        pcall(get_line, expected.dependency, reader)

                    local expected_reads = #expected.inputs
                    if reads ~= expected_reads then
                        fail(test.name, row,
                             "expected %d input reads, got %d",
                             expected_reads, reads)
                    end

                    if expected.change == ERROR then
                        if ok then
                            fail(test.name, row,
                                 "expected error %q, got line %q and change %s",
                                 expected.line, line, tostring(change))
                        end

                        if line ~= expected.line then
                            fail(test.name, row,
                                 "expected error %q, got %q",
                                 expected.line, line)
                        end

                        ended_with_error = true
                    else
                        if not ok then
                            fail(test.name, row,
                                 "unexpected error: %s", tostring(line))
                        end

                        local comparable_line = line

                        if type(expected.line) == "string"
                                and type(comparable_line) == "string"
                                and not expected.line:match("[ \t]$") then
                            comparable_line =
                                comparable_line:gsub("[ \t]+$", "")
                        end

                        if comparable_line ~= expected.line then
                            fail(test.name, row,
                                 "expected line %s, got %s",
                                 tostring(expected.line), tostring(line))
                        end

                        if change ~= expected.change then
                            fail(test.name, row,
                                 "expected change %s, got %s",
                                 expected.change_name, tostring(change))
                        end
                    end

                    local depth = #active_prefixes
                    if depth ~= expected.depth then
                        fail(test.name, row,
                             "expected depth %d, got %d",
                             expected.depth, depth)
                    end

                    if ended_with_error then
                        break
                    end
                end
            end
        end

        if #pending_inputs ~= 0 then
            error(("%s: source input without expectation")
                  :format(test.name), 0)
        end

        if not ended_with_error then
            local depth = #active_prefixes
            if depth ~= 0 then
                error(("%s: finished at depth %d"):format(test.name, depth), 0)
            end
        end

        print(test.name .. ": OK")
    end
end

run_get_line_tests(tests)
end
