--[[
    
New approach. You're going to write a new function called
get_line. You will keep it and its associated code in "scratch.lua"
We will debug it there as standalone code, using "./blud --lua scratch.lua".
You will add inline tests at the end of the file, in its own do/end block.
The function accepts a function that fetches the next line, which will allow
the unit tests to "fake" input to be tested.


parsed = get_line(next_func)

Where:
    next_func is a function fetches the next line of text.

    parsed is a table with these fields:
        type: "LUA" or "ASSIGN" or "ACTION" or "UNKNOWN" or "POP" or "EMPTY"
        keyword: if line starts with Lua keyword, text of that keyword, else nil
        parts: result of running macro.lua's parts_from_text on the "real"
            portion of the line
        line: the entire original line
        virtual_line: the entire original line minus prefix that was stripped

get_line() calls next_func() to get next line of text. It maintains an
internal 'mode' variable that is either "LUA" or "DIRECTIVE" or
"ACTION". This is initially set to "DIRECTIVE".

It also maintains an internal 'strip_stack', which contains a stack of
prefix contexts it is currently stripping off of input lines to get to
the "virtual" line. This is initially empty. Each element of
strip_stack is a table: { prefix, mode }

get_line first handles push/pop operations on the strip_stack. It
begins by trying to strip each prefix on the stack, bottom to top. If
it cannot find all the prefixes in order, it pops the topmost element,
sets the current mode to that element's .mode and returns a POP type.
The next call to get_line will operate on these same line instead of
calling next_func.
    
If it does find all the prefixes, then it sets its result virtual_line
to the remainder of the line. It next checks the beginning of virtual_line
for the presence of a new additional prefix. A prefix is one of three forms:

    <whitespace>:<space>
         or
    <whitespace>$<space>
         or
    <whitespace><not white-space>

If 

If the line starts with one of these patterns, the prefix text matched
is stripped and pushed onto the strip_stack before proceeding. The
current 'mode' is also pushed with that same entry. If the new prefix
was a colon type, our mode is set to DIRECTIVE. If it was the dollar
sign type or just whitespace then the mode is set to ACTION. There is
an exception: if the current mode is LUA and the prefix is just
whitespace, we pretend we saw no prefix at all.

Now we have the final virtual_line to analyze. parts_to_text is called
to produce a 'parts' array from virtual_line. We next must analyze the
parts array to determine the return type.

The first test is mode-independent. Does it look like an empty line
or a line that only contains a lua comment? In that case, just set the
return type to "EMPTY".

Otherwise, the analysis depends on the current mode:

In DIRECTIVE mode, 

The only indentations that get stacked are:
    * leading white space if previous line was dependency rule
    * switch to DIRECTIVE mode via ": "

State_0: DIRECTIVE mode
   EMPTY -> State_0
   
prog: prog.o
    if true then
        $ echo "true"
        : prog: prog.o
        if true then
            : foo : foo.o
            :     echo "but that's OK"
        end
    end

]]--

local PUSH      = "PUSH"
local PUSHCOLON = "PUSHCOLON"
local POP       = "POP"
local ERROR     = "ERROR"

local prefixes = {}
local pending_line
local pending_eof = false

local function normal_line_reader()
    return io.read("*l")
end

local function get_line_depth()
    return #prefixes
end

local function reset_get_line()
    prefixes = {}
    pending_line = nil
    pending_eof = false
end

local function strip_prefixes(line)
    local virtual = line

    for i = 1, #prefixes do
        local prefix = prefixes[i]

        if virtual:sub(1, #prefix) ~= prefix then
            return virtual, false
        end

        virtual = virtual:sub(#prefix + 1)
    end

    return virtual, true
end

local function is_blank(line)
    return line:match("^[ \t]*$") ~= nil
end

local function get_line(previous_was_dependency, line_reader)
    line_reader = line_reader or normal_line_reader

    while true do
        local line

        if pending_eof then
            line = nil
        elseif pending_line ~= nil then
            line = pending_line
            pending_line = nil
        else
            line = line_reader()
        end

        if line == nil then
            if #prefixes == 0 then
                pending_eof = false
                return "", nil
            end

            table.remove(prefixes)
            pending_eof = #prefixes > 0
            return "", POP
        end

        if not is_blank(line) then
            local virtual, matched = strip_prefixes(line)

            if not matched then
                table.remove(prefixes)
                virtual, matched = strip_prefixes(line)

                if not matched then
                    pending_line = line
                end

                return virtual, POP
            end

            if not is_blank(virtual) then
                if previous_was_dependency then
                    local indent, body = virtual:match("^([ \t]+)(.*)$")

                    if indent then
                        local directive = body:match("^: (.*)$")

                        if directive ~= nil then
                            if not is_blank(directive) then
                                table.insert(prefixes, indent)
                                table.insert(prefixes, ": ")
                                return directive, PUSHCOLON
                            end
                        else
                            table.insert(prefixes, indent)
                            return body, PUSH
                        end
                    end
                end

                local colon_prefix, body =
                    virtual:match("^([ \t]*: )(.*)$")

                if colon_prefix then
                    if not is_blank(body) then
                        table.insert(prefixes, colon_prefix)
                        return body, PUSHCOLON
                    end
                else
                    return virtual, nil
                end
            end
        end
    end
end






local tests = {
    { name="test0001", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",         nil
    echo 'simple action'    | true  =>[1] "echo 'simple action'", PUSH
EOF                         | false =>[0] "",                     POP
]]},
    { name="test0002", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",     nil
    if true then            | true  =>[1] "if true then",     PUSH
        : foo: foo.o        | false =>[2] "foo: foo.o",       PUSHCOLON
    end                     | true  =>[1] "end",              POP
EOF                         | false  =>[0] "",                 POP
]]},
    { name="test0003", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",     nil
    : foo: foo.o            | true  =>[2] "foo: foo.o",       PUSHCOLON
    :     echo 'foo'        | true  =>[3] "echo 'foo'",       PUSH
EOF                         | false =>[2] "",                 POP
|                             false =>[1] "",                 POP
|                             false =>[0] "",                 POP
]]},

    { name="test0004", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",         nil
    : foo: foo.o            | true  =>[2] "foo: foo.o",           PUSHCOLON
    :     echo 'foo'        | true  =>[3] "echo 'foo'",           PUSH
    echo 'building prog'    | false =>[2] "echo 'building prog'", POP
|                             false =>[1] "echo 'building prog'", POP
EOF                         | false =>[0] "",                     POP
]]},
    { name="test0005", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",         nil
    echo 'building prog'    | true  =>[1] "echo 'building prog'", PUSH
next: next.o                | false =>[0] "next: next.o",         POP
EOF                         | false =>[0] "",                     nil
]]},
    { name="test0006", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",         nil
    echo 'building prog'    | true  =>[1] "echo 'building prog'", PUSH
  next: next.o              | false =>[0] "  next: next.o",       POP
EOF                         | false =>[0] "",                     nil
]]},
    { name="test0007", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",          nil
    if true then            | true  =>[1] "if true then",          PUSH
        :not_a_directive()  | false =>[1] "    :not_a_directive()", nil
        : foo: foo.o        | false =>[2] "foo: foo.o",            PUSHCOLON
    end                     | true  =>[1] "end",                   POP
EOF                         | false =>[0] "",                      POP
]]},
    { name="test0008", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",          nil
    : foo: foo.o            | true  =>[2] "foo: foo.o",            PUSHCOLON
    :     echo 'foo'        | true  =>[3] "echo 'foo'",            PUSH
    echo 'building prog'    | false =>[2] "echo 'building prog'",  POP
|                             false =>[1] "echo 'building prog'",  POP
    echo 'still prog'       | false =>[1] "echo 'still prog'",     nil
EOF                         | false =>[0] "",                      POP
]]},
    { name="test0009", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",          nil
    : foo: foo.o            | true  =>[2] "foo: foo.o",            PUSHCOLON
    :     : bar: bar.o      | true  =>[4] "bar: bar.o",            PUSHCOLON
    echo 'building prog'    | true  =>[3] "echo 'building prog'",  POP
|                             false =>[2] "echo 'building prog'",  POP
|                             false =>[1] "echo 'building prog'",  POP
EOF                         | false =>[0] "",                      POP
]]},
    { name="test0010", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",          nil
next: next.o                | true  =>[0] "next: next.o",          nil
    echo 'building next'    | true  =>[1] "echo 'building next'",  PUSH
EOF                         | false =>[0] "",                      POP
]]},
    { name="test0011", text=[[
if true then                | false =>[0] "if true then",          nil
    : foo: foo.o            | false =>[1] "foo: foo.o",            PUSHCOLON
    :     echo 'foo'        | true  =>[2] "echo 'foo'",            PUSH
end                         | false =>[1] "end",                   POP
|                             false =>[0] "end",                   POP
EOF                         | false =>[0] "",                      nil
]]},
    { name="test0012", text=[[
prog: prog.o                                      | false =>[0] "prog: prog.o", nil
    : foo: foo.o                                  | true  =>[2] "foo: foo.o",   PUSHCOLON
READ {"", "    : ", "    :     echo 'foo'"}       | true  =>[3] "echo 'foo'",   PUSH
EOF                                               | false =>[2] "",             POP
|                                                   false =>[1] "",             POP
|                                                   false =>[0] "",             POP
]]},
    { name="test0013", text=[[
prog: prog.o                                      | false =>[0] "prog: prog.o", nil
    echo 'prog'                                   | true  =>[1] "echo 'prog'",  PUSH
READ {"", "   ", "    : ", false}                 | false =>[0] "",             POP
]]},
    { name="test0014", text=[[
: foo: foo.o                | false =>[1] "foo: foo.o",       PUSHCOLON
:     echo 'foo'            | true  =>[2] "echo 'foo'",       PUSH
EOF                         | false =>[1] "",                 POP
|                             false =>[0] "",                 POP
]]},
    { name="test0015", text=[[
prog: prog.o                         | false =>[0] "prog: prog.o", nil
READ {"\techo 'one'"}                 | true  =>[1] "echo 'one'",  PUSH
READ {"\techo 'two'"}                 | false =>[1] "echo 'two'",  nil
EOF                                  | false =>[0] "",            POP
]]},
    { name="test0016", text=[[
prog: prog.o                                      | false =>[0] "prog: prog.o", nil
READ {"", "   ", "    echo 'building prog'"}      | true  =>[1] "echo 'building prog'", PUSH
EOF                                               | false =>[0] "",             POP
]]},
    { name="test0017", text=[[
: if true then              | false =>[1] "if true then",       PUSHCOLON
:     print('true')         | false =>[1] "    print('true')",  nil
: end                       | false =>[1] "end",                nil
EOF                         | false =>[0] "",                   POP
]]},
    { name="test0018", text=[[
prog: prog.o                              | false =>[0] "prog: prog.o", nil
READ {"\t  : foo: foo.o"}                  | true  =>[2] "foo: foo.o",   PUSHCOLON
READ {"\t  : \techo 'foo'"}                | true  =>[3] "echo 'foo'",   PUSH
EOF                                       | false =>[2] "",             POP
|                                           false =>[1] "",             POP
|                                           false =>[0] "",             POP
]]},
    { name="test0019", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",       nil
    if true then            | true  =>[1] "if true then",       PUSH
        : foo: foo.o        | false =>[2] "foo: foo.o",         PUSHCOLON
        :     echo 'foo'    | true  =>[3] "echo 'foo'",         PUSH
    : bar: bar.o            | false =>[2] ": bar: bar.o",       POP
|                             false =>[1] ": bar: bar.o",       POP
EOF                         | false =>[0] "",                   POP
]]},
    { name="test0020", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",       nil
    : prog: oslinux.o       | true  =>[2] "prog: oslinux.o",    PUSHCOLON
    :     : CFLAGS += -g    | true  =>[4] "CFLAGS += -g",       PUSHCOLON
EOF                         | false =>[3] "",                   POP
|                             false =>[2] "",                   POP
|                             false =>[1] "",                   POP
|                             false =>[0] "",                   POP
]]},
    { name="test0021", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",       nil
    : prog: oslinux.o       | true  =>[2] "prog: oslinux.o",    PUSHCOLON
    : : CFLAGS += -g        | true  =>[3] "CFLAGS += -g",       PUSHCOLON
EOF                         | false =>[2] "",                   POP
|                             false =>[1] "",                   POP
|                             false =>[0] "",                   POP
]]},
    { name="test0022", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",       nil
    : foo: foo.o            | true  =>[2] "foo: foo.o",         PUSHCOLON
    :     : CFLAGS += -g    | true  =>[4] "CFLAGS += -g",       PUSHCOLON
    : bar: bar.o            | false =>[3] "bar: bar.o",         POP
|                             false =>[2] "bar: bar.o",         POP
EOF                         | false =>[1] "",                   POP
|                             false =>[0] "",                   POP
]]},
    { name="test0023", text=[[
prog: prog.o                | false =>[0] "prog: prog.o",       nil
    echo 'prog'             | true  =>[1] "echo 'prog'",        PUSH
: foo: foo.o                | false =>[0] ": foo: foo.o",       POP
]]},
    { name="test0024", text=[[
if true then                | false =>[0] "if true then",       nil
    : prog: prog.o          | false =>[1] "prog: prog.o",       PUSHCOLON
    :     echo 'prog'       | true  =>[2] "echo 'prog'",        PUSH
  : foo: foo.o              | false =>[1] "  : foo: foo.o",     POP
|                             false =>[0] "  : foo: foo.o",     POP
EOF                         | false =>[0] "",                   nil
]]},
}

local test0001 = [[
prog: prog.o                              -- { type='LINE' }
    if true then                          -- { type='PUSHINDENT' }  { type='LINE' }
        $ echo "true"                     -- { type='LINE' }
                                          -- { type='EMPTY' }
        if true then                      -- { type='LINE' }
            $ echo "false"
            $ echo "but that's ok"
        end
    end                                   -- { type='LINE' }
                                          -- { type='POPINDENT' } { type='EMPTY' }
]]

local test0002 = [[
if true then                          -- { type='LINE' }
    $ echo "true"                     -- { type='LINE' }
                                      -- { type='EMPTY' }
    : prog: prog.o
        if true then                  -- { type='PUSHINDENT' }
            : foo : foo.o
            :     echo "but that's ok"
        end
end                                   -- { type='POPINDENT' }

]]
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
    local input, expected = text:match("^(.-)|%s*(.-)%s*$")
    if not input then
        fail(test, row, "missing |")
    end

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

    input = input:gsub("%s+$", "")

    local inputs
    local input_expression = input:match("^READ%s+(.+)$")

    if input_expression then
        local input_loader, input_message =
            loadstring("return " .. input_expression)

        if not input_loader then
            fail(test, row, "%s", input_message)
        end

        inputs = input_loader()

        if type(inputs) ~= "table" then
            fail(test, row, "READ input must be a table")
        end

        for i = 1, #inputs do
            if type(inputs[i]) ~= "string" and inputs[i] ~= false then
                fail(test, row,
                     "READ input %d must be a string or false", i)
            end
        end
    elseif input == "" then
        inputs = {}
    elseif input == "EOF" then
        inputs = { false }
    elseif input == "EMPTY" then
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
        reset_get_line()
        local row = 0
        local ended_with_error = false

        for text in (test.text .. "\n"):gmatch("(.-)\n") do
            if text:match("%S") then
                row = row + 1
                local expected = parse_row(test.name, row, text)
                local reads = 0

                local function reader()
                    reads = reads + 1

                    if #expected.inputs == 0 then
                        fail(test.name, row, "get_line unexpectedly read input")
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

                    if line ~= expected.line then
                        fail(test.name, row,
                             "expected line %q, got %q",
                             expected.line, line)
                    end

                    if change ~= expected.change then
                        fail(test.name, row,
                             "expected change %s, got %s",
                             expected.change_name, tostring(change))
                    end
                end

                local depth = get_line_depth()
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

        if not ended_with_error then
            local depth = get_line_depth()
            if depth ~= 0 then
                error(("%s: finished at depth %d"):format(test.name, depth), 0)
            end
        end

        print(test.name .. ": OK")
    end
end

run_get_line_tests(tests)
end
