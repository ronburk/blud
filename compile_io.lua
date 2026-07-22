-- Compiler I/O: reads stacked source inputs, emits generated Lua, and tracks source mappings.

local M = {}

local pre_sourcemap  = ""
local sourcemap_gap  = nil
local post_sourcemap = nil
local sourcemap      = {}  -- [{filename, source_ln, dest_ln}]
local next_output_ln = 1
local input_stack    = {}
local current_input  = nil   -- physical input plus current virtual line

local function count_nl(text)  -- return count of newlines in a string
    return select(2, text:gsub("\n", "\n"))
end

local function append_output_text(text)
    if post_sourcemap then
        post_sourcemap = post_sourcemap .. text
    else
        pre_sourcemap  = pre_sourcemap .. text
    end
end


-- emit an entire file (possibly virtual) verbatim
function M.emit_file(name, text)
    local entry = {filename=name, source_ln=1, dest_ln=next_output_ln}
    table.insert(sourcemap, entry);
    next_output_ln = next_output_ln + count_nl(text)
    append_output_text(text)
end

M.push_input = function(name, text)
    if current_input then
        table.insert(input_stack, current_input)
    end
    current_input = {
        name = name,
        text = text,
        physical_pos = 1,
        next_source_ln = 1,
        source_ln = 1,
        line_state = nil,
        current_line = nil,
    }
end

--[[
get_line() is the structural line reader shared by parsers nested inside one
another. It removes the structural prefix belonging to the surrounding
parsers, returns the remaining virtual line, and reports at most one stack
event:

    PUSH        enter an action-indentation boundary
    PUSHCOLON   enter a ": " directive boundary
    POP         leave one boundary
    nil         no boundary changed

The public call returns `line, change, again`. When `again` is true, the
reported structural event is not yet accompanied by a line that the new
parser context may tokenize; the caller must call get_line() again. When it
is false, any returned line is ready for the parser selected by `change`.

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

M.PUSH      = PUSH
M.PUSHCOLON = PUSHCOLON
M.POP       = POP

local function new_line_state()
    return {
        active_prefixes = {},
        pending_line = nil,
    }
end

local function ensure_line_state(input)
    if input.line_state == nil then
        input.line_state = new_line_state()
    end
    return input.line_state
end

-- Strip complete active-prefix entries until the first mismatch. The returned
-- depth identifies the inherited leading portion of active_prefixes; this
-- function does not modify the stack.
local function strip_active_prefixes(state, line)
    local virtual_line = line

    for i = 1, #state.active_prefixes do
        local prefix = state.active_prefixes[i]

        if virtual_line:sub(1, #prefix) ~= prefix then
            return virtual_line, i - 1
        end

        virtual_line = virtual_line:sub(#prefix + 1)
    end

    return virtual_line, #state.active_prefixes
end

local function is_whitespace_only(line)
    return line:match("^[ \t]*$") ~= nil
end

local function split_directive_prefix(line)
    return line:match("^([ \t]*: )(.*)$")
end

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

local function validate_line_prefix(state, line)
    local directive_prefix = split_directive_prefix(line)

    if #state.active_prefixes == 0 or directive_prefix == ": " then
        return
    end

    local active_prefix = table.concat(state.active_prefixes)
    local line_prefix = leading_structural_prefix(line)
    local common_length = math.min(#line_prefix, #active_prefix)

    if line_prefix:sub(1, common_length)
            ~= active_prefix:sub(1, common_length) then
        local shown_line_prefix = line_prefix:gsub("\t", "\t")
        local shown_active_prefix = active_prefix:gsub("\t", "\t")

        error(('indentation prefix "%s" does not align with active prefix "%s"')
              :format(shown_line_prefix, shown_active_prefix), 0)
    end
end

local function start_indented_block_after_dependency(state, virtual_line)
    local indentation, indented_line =
        virtual_line:match("^([ \t]+)(.*)$")

    if not indentation then
        return nil
    end

    local directive_body = indented_line:match("^: (.*)$")

    if directive_body == nil then
        table.insert(state.active_prefixes, indentation)
        return indented_line, PUSH
    end

    if not is_whitespace_only(directive_body) then
        table.insert(state.active_prefixes, indentation)
        return nil, PUSH, {
            virtual_line = indented_line,
            inherited_depth = #state.active_prefixes,
        }
    end

    return nil
end

-- The fourth return value is the physical source line. The third says the
-- caller must consume another structural event before tokenizing any text.
local function get_structural_line(state, after_dependency, line_reader)
    while true do
        local line = state.pending_line
        state.pending_line = nil

        if line == nil then
            local physical_line, source_ln = line_reader()

            if physical_line == nil then
                if #state.active_prefixes == 0 then
                    return "", nil, false, nil
                end

                table.remove(state.active_prefixes)
                return "", POP, #state.active_prefixes > 0, nil
            end

            if not is_whitespace_only(physical_line) then
                validate_line_prefix(state, physical_line)

                local virtual_line, inherited_depth =
                    strip_active_prefixes(state, physical_line)

                line = {
                    virtual_line = virtual_line,
                    inherited_depth = inherited_depth,
                    source_ln = source_ln,
                }
            end
        end

        if line ~= nil then
            if #state.active_prefixes > line.inherited_depth then
                table.remove(state.active_prefixes)

                local again = #state.active_prefixes > line.inherited_depth
                    or split_directive_prefix(line.virtual_line) ~= nil

                if again then
                    state.pending_line = line
                end

                return line.virtual_line, POP, again, line.source_ln
            end

            local virtual_line = line.virtual_line

            if not is_whitespace_only(virtual_line) then
                if after_dependency then
                    local returned_line, stack_event, again_line =
                        start_indented_block_after_dependency(state, virtual_line)

                    if stack_event ~= nil then
                        if again_line ~= nil then
                            again_line.source_ln = line.source_ln
                        end
                        state.pending_line = again_line
                        return returned_line, stack_event,
                               again_line ~= nil, line.source_ln
                    end
                end

                local directive_prefix, directive_body =
                    split_directive_prefix(virtual_line)

                if not directive_prefix then
                    return virtual_line, nil, false, line.source_ln
                end

                if not is_whitespace_only(directive_body) then
                    table.insert(state.active_prefixes, directive_prefix)
                    return directive_body, PUSHCOLON, false, line.source_ln
                end
            end
        end
    end
end

local function read_physical_line(input)
    local pos = input.physical_pos
    local text = input.text

    if pos > #text then
        return nil
    end

    local newline_pos = text:find("\n", pos, true)
    local line

    if newline_pos then
        line = text:sub(pos, newline_pos - 1)
        input.physical_pos = newline_pos + 1
    else
        line = text:sub(pos)
        input.physical_pos = #text + 1
    end

    local source_ln = input.next_source_ln
    input.next_source_ln = source_ln + 1
    return line, source_ln
end

local function set_current_line(input, text, source_ln, eof)
    input.source_ln = source_ln or input.next_source_ln
    input.current_line = {
        text = text or "",
        pos = 1,
        at_word_start = true,
        eol_returned = false,
        eof = eof or false,
    }
end

function M.get_line(after_dependency)
    assert(current_input, "get_line() requires an active input")

    while true do
        local input = current_input
        local state = ensure_line_state(input)
        local line, change, again, source_ln = get_structural_line(
            state,
            after_dependency,
            function()
                return read_physical_line(input)
            end
        )

        local at_input_eof = line == "" and change == nil
            and source_ln == nil and input.physical_pos > #input.text

        if at_input_eof and #input_stack > 0 then
            current_input = table.remove(input_stack)
        else
            set_current_line(input, line, source_ln, at_input_eof)
            return line, change, again
        end
    end
end

local function match_colon_operator(text, pos)
    local stop = text:match("^:[%a_][%w_]*:()", pos)
    if stop then
        return text:sub(pos, stop - 1)
    end
    if text:sub(pos, pos + 1) == "::" then
        return "::"
    end
    return ":"
end

local lua_block_start_words = {
    ["do"]       = true,
    ["if"]       = true,
    ["for"]      = true,
    ["while"]    = true,
    ["repeat"]   = true,
    ["function"] = true,
}

local lua_line_words = {
    ["end"]     = "LUAEND",
    ["else"]    = "LUA_ELSE",
    ["elseif"]  = "LUA_ELSEIF",
    ["until"]   = "LUA_UNTIL",
}

local function remainder_starts_function(text, pos)
    local stop = text:match("^[ \t]*function()", pos)
    if not stop then
        return false
    end

    local next_char = text:sub(stop, stop)
    return next_char == "" or not next_char:match("[%w_]")
end

local function scan_dependency_word(text, pos)
    local start = pos

    while pos <= #text do
        local c = text:sub(pos, pos)
        if c == " " or c == "\t" or c == ":"
                or c == "=" or c == "+" or c == "?" then
            break
        end
        if c == "-" and text:sub(pos, pos + 1) == "--" then
            break
        end
        pos = pos + 1
    end
    return text:sub(start, pos - 1)
end

local function current_virtual_line()
    assert(current_input and current_input.current_line,
           "token operation requires get_line() first")
    return current_input.current_line
end

M.get_token = function()
    local line = current_virtual_line()

    if line.eof then
        return "EOF", ""
    end

    local text = line.text
    local pos = line.pos

    if pos > #text then
        if not line.eol_returned then
            line.eol_returned = true
            return "EOL", "\n"
        end
        return "EOF", ""
    end

    local token_type
    local token_text
    local char = text:sub(pos, pos)
    local at_word_start = line.at_word_start

    if at_word_start and (char == " " or char == "\t") then
        token_type = "LEADWHITE"
        token_text = text:match("^[ \t]+", pos)
    elseif text:sub(pos, pos + 1) == "--" then
        token_type = "COMMENT"
        token_text = text:sub(pos)
    elseif char == ":" then
        token_type = "COLON_OP"
        token_text = match_colon_operator(text, pos)
    else
        token_text = char .. scan_dependency_word(text, pos + 1)

        if at_word_start and lua_block_start_words[token_text] then
            token_type = "LUASTART"
        elseif at_word_start and token_text == "local"
                and remainder_starts_function(text, pos + #token_text) then
            token_type = "LUASTART"
        elseif at_word_start and lua_line_words[token_text] then
            token_type = lua_line_words[token_text]
        else
            token_type = "WORD"
        end
    end

    line.pos = pos + #token_text
    if token_type ~= "LEADWHITE" then
        line.at_word_start = false
    end
    return token_type, token_text
end

M.get_line_remainder = function()
    local line = current_virtual_line()
    local result = line.text:sub(line.pos)
    line.pos = #line.text + 1
    return result
end

M.skip_white = function()
    local line = current_virtual_line()
    local white = line.text:match("^[ \t]*", line.pos)
    line.pos = line.pos + #white
end

M.get_assign_op = function()
    local line = current_virtual_line()
    local result, discard

    discard, result = line.text:match("^([ \t]*)(%?=)", line.pos)
    if not result then
        discard, result = line.text:match("^([ \t]*)(%+=)", line.pos)
    end
    if not result then
        discard, result = line.text:match("^([ \t]*)(=)", line.pos)
    end
    assert(result)
    line.pos = line.pos + #discard + #result
    return result
end


-- don't really emit sourcemap, just start accumulating in a new place
function M.emit_sourcemap()
    assert(post_sourcemap == nil)
    -- signal that it's time to start appending to a different place
    post_sourcemap = ""
    -- add virtual entry to source map
    local entry = {filename="<sourcemap>", source_ln=1, dest_ln = next_output_ln}
    table.insert(sourcemap, entry);
    -- remember where we will later backpatch
    sourcemap_gap = #sourcemap
end


local function need_new_sourcemap_entry(previous_entry, current_input)
    local need_entry = false
    -- if no existing entry to extend, then need new entry
    if previous_entry == nil then
        need_entry = true
    elseif current_input.name ~= previous_entry.filename then
        need_entry = true
    elseif previous_entry.source_ln ~= current_input.source_ln then
        need_entry = true
    end
--[[    print(
        string.format(
            "[%d] prev name=%s, source_ln=%d \n returns %s", #sourcemap,
            previous_entry.filename, previous_entry.source_ln, need_entry
    ))
]]
    return need_entry
end

function M.emit_line(fmt, ...)
    if not current_input then
        error("Must not call emit_line when no active input (I have no filename!)")
    end
    
    local text = string.format(fmt, ...)
    if text:sub(-1) ~= '\n' then text = text .. '\n' end

    -- see if we can skip adding a new map entry
    local need_entry = false
    local line_count = count_nl(text)
    
    -- if more than one output line for this input, or if it's a new file
    if line_count > 1 or need_new_sourcemap_entry(sourcemap[#sourcemap], current_input) then
        need_entry = true
    end
    if need_entry then
        for i = 1, line_count do
            local entry = {
                filename=current_input.name,
                source_ln=current_input.source_ln,
                dest_ln=next_output_ln
            }
            table.insert(sourcemap, entry)
            next_output_ln = next_output_ln + 1
        end
    else
        next_output_ln = next_output_ln + line_count
    end
    append_output_text(text)
end

local function sourcemap_to_lua(map)
    local result = "blud.sourcemap = {\n"
    for i = 1, #sourcemap do
        local entry = sourcemap[i]
        result = result .. string.format(
            "    {filename=%q, source_ln=%d, dest_ln=%d},\n",
            entry.filename, entry.source_ln, entry.dest_ln)
    end
    result = result .. "    }\n"
    return result
end

local function error_get_line(text, source_ln)
    local current = 1
    for line in text:gmatch("[^\n]*\n?") do
        if current == source_ln then
            return line:match("([^\n]*)")  -- strip trailing newline
        end
        current = current + 1
    end
    error(string.format("Source line %d out of range\n", source_ln))
    return nil  -- line number out of range
end

M.get_current_line = function()
    local line = current_virtual_line()
    line.pos = #line.text + 1
    return line.text
end

M.peek_assign = function(text, position)
    if not text then
        local line = current_virtual_line()
        text = line.text
        position = line.pos
    end

    if text:match("^[ \t]*%?=", position) then
        return true
    elseif text:match("^[ \t]*%+=", position) then
        return true
    elseif text:match("^[ \t]*=", position) then
        return true
    end
    return false
end

function M.error(fmt, ...)
    local text = string.format(fmt, ...)
    local source_line = error_get_line(
        current_input.text,
        current_input.source_ln
    )
    local headline, details = text:match("^([^\n]*)(.*)$")
    local message = string.format(
        "%s:%d: %s\n%s%s",
        current_input.name,
        current_input.source_ln,
        headline,
        source_line,
        details
    )
    error("BLUD_COMPILE_ERROR:" .. message, 0)
end

-- close(): insert sourcemap in the gap, fix up the line numbers that follow, return text
function M.close()
    assert(sourcemap_gap ~= nil, "Did you forget to call emit_sourcemap()?")
    local sourcemap_lua = sourcemap_to_lua(sourcemap)
    local line_count    = count_nl(sourcemap_lua)
    local entry         = sourcemap[sourcemap_gap]
--    local new_entry     = {filename="<sourcemap>", source_ln=1, dest_ln=entry.dest_ln}
--    table.insert(sourcemap, sourcemap_gap, new_entry);
    for i = sourcemap_gap+1, #sourcemap do
        sourcemap[i].dest_ln = sourcemap[i].dest_ln + line_count
    end
    sourcemap_lua = sourcemap_to_lua(sourcemap)
    return pre_sourcemap .. sourcemap_lua .. post_sourcemap
end

---[=[UNIT_TESTS
do
    local saved_current_input = current_input
    local saved_input_stack = input_stack

    local function reset_input(text)
        current_input = nil
        input_stack = {}
        M.push_input("<compile_io token test>", text)
        local line, change = M.get_line(false)
        assert(change == nil and line ~= "")
    end

    local function assert_first_token(text, expected_type, expected_text,
                                      expected_remainder)
        reset_input(text)
        local token_type, token_text = M.get_token()

        assert(
            token_type == expected_type and token_text == expected_text,
            string.format(
                "%q: expected %s %q, got %s %q",
                text,
                expected_type,
                expected_text,
                token_type,
                token_text
            )
        )
        assert(
            M.get_line_remainder() == expected_remainder,
            string.format("%q: tokenizer consumed too much input", text)
        )
    end

    assert_first_token("do", "LUASTART", "do", "")
    assert_first_token("if condition then", "LUASTART", "if", " condition then")
    assert_first_token("for i = 1, 10 do", "LUASTART", "for", " i = 1, 10 do")
    assert_first_token("while condition do", "LUASTART", "while", " condition do")
    assert_first_token("repeat", "LUASTART", "repeat", "")
    assert_first_token("function f()", "LUASTART", "function", " f()")
    assert_first_token("local function f()", "LUASTART", "local", " function f()")
    assert_first_token("    do", "LEADWHITE", "    ", "do")

    assert_first_token("end", "LUAEND", "end", "")
    assert_first_token("else", "LUA_ELSE", "else", "")
    assert_first_token("elseif ready then", "LUA_ELSEIF", "elseif", " ready then")
    assert_first_token("until ready", "LUA_UNTIL", "until", " ready")

    assert_first_token("done", "WORD", "done", "")
    assert_first_token("iffy", "WORD", "iffy", "")
    assert_first_token("formatter", "WORD", "formatter", "")
    assert_first_token("local value", "WORD", "local", " value")
    assert_first_token("local functionary", "WORD", "local", " functionary")
    assert_first_token("TEST=foo", "WORD", "TEST", "=foo")

    reset_input("    do")
    assert(M.get_token() == "LEADWHITE")
    local token_type, token_text = M.get_token()
    assert(token_type == "LUASTART" and token_text == "do")

    current_input = nil
    input_stack = {}
    M.push_input("<virtual line boundary>", "first: one\nsecond: two")
    assert(M.get_line(false) == "first: one")
    assert(M.get_current_line() == "first: one")
    assert(M.get_token() == "EOL")
    assert(M.get_token() == "EOF")
    assert(M.get_line(false) == "second: two")
    assert(M.get_current_line() == "second: two")
    assert(M.get_token() == "EOL")
    assert(M.get_line(false) == "")
    assert(M.get_token() == "EOF")

    current_input = nil
    input_stack = {}
    M.push_input("<outer>", "outer")
    M.push_input("<inner>", "inner")
    assert(M.get_line(false) == "inner")
    assert(current_input.name == "<inner>" and current_input.source_ln == 1)
    assert(M.get_line(false) == "outer")
    assert(current_input.name == "<outer>" and current_input.source_ln == 1)

    current_input = nil
    input_stack = {}
    M.push_input(
        "<structural source lines>",
        "prog: prog.o\n  : nested:\n  :   touch result\nouter:"
    )
    assert(M.get_line(false) == "prog: prog.o")
    assert(current_input.source_ln == 1)
    local line, change = M.get_line(true)
    assert(line == nil and change == PUSH)
    assert(current_input.source_ln == 2)
    line, change = M.get_line(false)
    assert(line == "nested:" and change == PUSHCOLON)
    assert(current_input.source_ln == 2)
    line, change = M.get_line(true)
    assert(line == "touch result" and change == PUSH)
    assert(current_input.source_ln == 3)

    current_input = saved_current_input
    input_stack = saved_input_stack
end

local ERROR = "ERROR"

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
        local state = new_line_state()
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
                        pcall(get_structural_line, state, expected.dependency, reader)

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

                    local depth = #state.active_prefixes
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
            local depth = #state.active_prefixes
            if depth ~= 0 then
                error(("%s: finished at depth %d"):format(test.name, depth), 0)
            end
        end

    end
end

run_get_line_tests(tests)
end

--]=]

return M
