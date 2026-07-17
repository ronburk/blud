-- Compiler I/O: reads stacked source inputs, emits generated Lua, and tracks source mappings.

local M = {}

local pre_sourcemap  = ""
local sourcemap_gap  = nil
local post_sourcemap = nil
local sourcemap      = {}  -- [{filename, source_ln, dest_ln}]
local next_output_ln = 1
local input_stack    = {}
local current_input  = nil   -- {name, text, source_ln, pos, eol}

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
    if current_input then   -- stack current input if any
        table.insert(input_stack, current_input)
    end
    current_input = { name=name, text=text, source_ln=1, pos=1, eol=true }
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
        if c == " " or c == "\t" or c == "\n" or c == ":" then
            break
        end
        if c == "-" and text:sub(pos, pos + 1) == "--" then
            break
        end
        pos = pos + 1
    end
    return text:sub(start, pos - 1)
end

local strip_stack = {}

M.push_strip_prefix = function(prefix)
    assert(type(prefix) == "string" and prefix ~= "")
    table.insert(strip_stack, prefix)
end

local strip_prefix = function()
    local pos = current_input.pos

    for i = 1, #strip_stack do
        local prefix = strip_stack[i]
        if current_input.text:sub(pos, pos + #prefix - 1) ~= prefix then
            table.remove(strip_stack)
            return "STRIP_END", ""
        end
        pos = pos + #prefix
    end

    current_input.pos = pos
end

M.get_token = function()
    local token_type, token_text
    local at_line_start = current_input.eol

    if current_input.eol then
        token_type, token_text = strip_prefix()
        if token_type then
            return token_type, token_text
        end
    end

    local text = current_input.text
    local pos  = current_input.pos
    local char = text:sub(pos, pos)

    if pos > #text then return "EOF", "" end
    if current_input.eol and (char == " " or char == "\t") then
        token_type = "LEADWHITE"
        token_text = text:match("^[ \t]+", pos)
    elseif text:sub(pos, pos+1) == "--" then
        token_type = "COMMENT"
        token_text = text:match("^%-%-[^\n]*", pos)
    elseif char == '\n' then
        token_type = "EOL"
        token_text = char
        current_input.source_ln = current_input.source_ln + 1
    elseif char == ':' then
        token_type = "COLON_OP"
        token_text = match_colon_operator(text, pos)
    elseif char == '' then
        -- fake EOL if input did not end in newline
        if not current_input.eol then
            token_type = "EOL"
            token_text = '\n'
        elseif #input_stack > 0 then
            current_input = table.remove(input_stack)
            return M.get_token()
        else
            token_type = "EOF"
            token_text = ""
        end
    else
        token_text = char .. scan_dependency_word(text, pos + 1)

        if at_line_start and (
            lua_block_start_words[token_text] or
            token_text == "local" and
                remainder_starts_function(text, pos + #token_text)
        ) then
            token_type = "LUASTART"
        else
            token_type = "WORD"
        end
    end
    
    current_input.pos = pos + #token_text
    current_input.eol = (token_type == "EOL")
    return token_type, token_text
end

M.get_line_remainder = function()
    local pos    = current_input.pos
    local result = current_input.text:match("^[^\n]*", pos)
    pos = pos + #result
    current_input.pos = pos
    return result
end


M.skip_white = function()  -- skip over spaces and tabs
    local pos   = current_input.pos
    local white = current_input.text:match("^[ \t]*", pos)
    pos = pos + #white
    current_input.pos = pos
end



M.get_assign_op = function()
    local result, discard
    local pos  = current_input.pos
    local text = current_input.text
    discard, result = text:match("^([ \t]*)(%?=)", pos)
    if not result then
        discard, result = text:match("^([ \t]*)(%+=)", pos)
    end
    if not result then
        discard, result = text:match("^([ \t]*)(=)", pos)
    end
    assert(result) -- we should not get called unless assign op known to exist
    pos = pos + #discard + #result
    current_input.pos = pos
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
    local text = current_input.text
    local pos  = current_input.pos

    while pos > 1 and text:sub(pos - 1, pos - 1) ~= "\n" do
        pos = pos - 1
    end
    assert(pos == 1 or text:sub(pos - 1, pos - 1) == "\n")
    local newline_pos = text:find("\n", pos, true)
    local line

    if newline_pos then
        line = text:sub(pos, newline_pos - 1)
    else
        line = text:sub(pos)
    end    
    pos = pos + #line
    current_input.pos = pos
    return line
end
    
M.is_indented_line = function()
    local pos  = current_input.pos
    local text = current_input.text

    if not(pos == 1 or text:sub(pos - 1, pos - 1) == "\n") then
        error(string.format("M.is_indented_line() pos=%d", pos))
    end

    return text:find("^[ \t]+[^ \t\n]", pos) ~= nil
end


M.peek_assign = function(text, position)
    local result = false
    local anchor = ""

    if not text then
        text     = current_input.text
        position = current_input.pos
    end
    local pattern = anchor .. ""
    if text:match("^[ \t]*%?=", position) then
        result = true
    elseif text:match("^[ \t]*%+=", position) then
        result = true
    elseif text:match("^[ \t]*=", position) then
        result = true
    end
    return result
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
    local saved_strip_stack = strip_stack

    local function reset_input(text)
        current_input = nil
        input_stack = {}
        strip_stack = {}
        M.push_input("<compile_io token test>", text .. "\n")
    end

    local function assert_first_token(text, expected_type, expected_text, expected_remainder)
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

    assert_first_token("done", "WORD", "done", "")
    assert_first_token("iffy", "WORD", "iffy", "")
    assert_first_token("formatter", "WORD", "formatter", "")
    assert_first_token("local value", "WORD", "local", " value")
    assert_first_token("local functionary", "WORD", "local", " functionary")
    assert_first_token("end", "WORD", "end", "")
    assert_first_token("until condition", "WORD", "until", " condition")

    reset_input("while condition do")
    assert(M.get_token() == "LUASTART")
    M.skip_white()
    assert(M.get_token() == "WORD")
    M.skip_white()
    local token_type, token_text = M.get_token()
    assert(token_type == "WORD" and token_text == "do")

    reset_input("    do")
    token_type, token_text = M.get_token()
    assert(token_type == "LEADWHITE" and token_text == "    ")

    reset_input(": do")
    M.push_strip_prefix(": ")
    token_type, token_text = M.get_token()
    assert(token_type == "LUASTART" and token_text == "do")

    current_input = saved_current_input
    input_stack = saved_input_stack
    strip_stack = saved_strip_stack
end
--]=]

return M
