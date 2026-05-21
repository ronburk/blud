-- compile_io.lua: I/O object for compiler

local M = {}

local pre_sourcemap  = ""
local sourcemap_gap  = nil
local post_sourcemap = nil
local sourcemap      = {}  -- [{filename, source_ln, dest_ln}]
local next_output_ln = 1
local input_stack    = {}
local current_input  = nil   -- {name, text, source_ln, reader, previous_line}
local reread         = false

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
    table.insert(map, entry);
    next_output_ln = next_output_ln + count_nl(text)
    append_output_text(text)
end

-- lines: return an iterator that returns one line of the string at a time
local function lines(str)
    local pos = 1
    return function()
        if pos > #str then return nil end
        local nl = str:find("\n", pos, true)
        local line
        if nl then
            line = str:sub(pos, nl - 1)
            pos = nl + 1
        else
            line = str:sub(pos)
            pos = #str + 1
        end
        if line:sub(-1) == "\r" then
            line = line:sub(1, -2)
        end
        return line
    end
end

-- push an input "file" that will be read by get_line()
M.push_input = function(name, text)
    local reader= lines(text)
    current_input = { name=name, text=text, source_ln=1, reader=reader }
    table.insert(input_stack, current_input)
end
local pos = 1 --???
local eol = true

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


M.get_token = function()
    local token_type, token_text
    local text = current_input.text
    local char = text:sub(pos, pos)
    if eol and char == " " then
        token_type = "LEADWHITE"
        token_text = text:match("^[ \t]+", pos)
    elseif text:sub(pos, pos+1) == "--" then
        token_type = "COMMENT"
        token_text = text:match("^%-%-[^\n]*", pos)
    elseif char == '\n' then
        token_type = "EOL"
        token_text = char
        current_input.source_ln = current_input.source_ln + 1
    elseif char:match("[.%a_]") then
        token_type = "IDENT"
        token_text = text:match("^[.%a_]+", pos)
    elseif char == ':' then
        token_type = "COLON_OP"
        token_text = match_colon_operator(text, pos)
    elseif char == '' then
        token_type = "EOF"
        token_text = ""
    else
        error("Unknown char: '" .. char .. "'")
    end
    
    pos = pos + #token_text
    eol = (token_type == "EOL")
--    print(string.format("[%s]=%q", token_type, token_text))
    return token_type, token_text
end

M.get_line_remainder = function()
    local result = current_input.text:match("^[^\n]*", pos)
    pos = pos + #result
    return result
end

M.skip_white = function()
    local white = current_input.text:match("^[ \t]*", pos)
    pos = pos + #white
end



M.get_assign_op = function()
    local result, discard
    local text = current_input.text
    discard, result = text:match("^([ \t]*)(:=)", pos)
    if not result then
        discard, result = text:match("^([ \t]*)(+=)", pos)
    end
    if not result then
        discard, result = text:match("^([ \t]*)(=)", pos)
    end
    assert(result) -- we should not get called unless assign op known to exist
    pos = pos + #discard + #result
    return result
end


function M.reread()
    assert(current_input)
    assert(current_input.previous_line)
    reread = true
end

-- get the next line of input, popping the input stack if necessary
function M.get_line()
    local result
    while current_input do
        if reread == true then
            result = current_input.previous_line
            reread = false
        else
            current_input.previous_line = current_input.reader()
            result = current_input.previous_line
            if result ~= nil then
                current_input.source_ln = current_input.source_ln + 1
                return result
            else
                input_stack[#input_stack] = nil -- pop exhausted input
                current_input = input_stack[#input_stack]
            end
        end
    end
    return nil
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
    print(
        string.format(
            "[%d] prev name=%s, source_ln=%d \n returns %s", #sourcemap,
            previous_entry.filename, previous_entry.source_ln, need_entry
    ))
    return need_entry
end

function M.emit_line(fmt, ...)
    assert(#input_stack > 0) -- should not be called when no active input

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
    return line
end
    
M.is_indented_line = function()
    return current_input.text:match("^[ \t]+[^ \t\n]", pos)
end


M.peek_assign = function(text, position)
    local result = false
    local anchor = ""

    if not text then
        text     = current_input.text
        position = pos
    end
    local pattern = anchor .. ""
    if text:match("^[ \t]*:=", position) then
        result = true
    elseif text:match("^[ \t]*+=", position) then
        result = true
    elseif text:match("^[ \t]*=", position) then
        result = true
    end
    return result
end

function M.error(fmt, ...)
    local text = string.format(fmt, ...)
    local where = string.format("%s\nFile %s, line %d\n",
                            error_get_line(current_input.text, current_input.source_ln),
                            current_input.name,
                            current_input.source_ln)
    error(where .. text)
end

-- close(): insert sourcemap in the gap, fix up the line numbers that follow, return text
function M.close()
    assert(sourcemap_gap ~= nil, "Did you forget to call emit_sourcemap()?")
    local sourcemap_lua = sourcemap_to_lua(sourcemap)
    local line_count    = count_nl(sourcemap_lua)
    local entry         = sourcemap[sourcemap_gap]
    print("sourcemap_gap =", sourcemap_gap, "  #sourcemap =", #sourcemap)
--    local new_entry     = {filename="<sourcemap>", source_ln=1, dest_ln=entry.dest_ln}
--    table.insert(sourcemap, sourcemap_gap, new_entry);
    for i = sourcemap_gap+1, #sourcemap do
        sourcemap[i].dest_ln = sourcemap[i].dest_ln + line_count
    end
    return pre_sourcemap .. sourcemap_lua .. post_sourcemap
end

return M
