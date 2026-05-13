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
    current_input = { name=name, text=text, source_ln=0, reader=reader }
    table.insert(input_stack, current_input)
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
            "    {filename=%q, source_ln=%d, dest_ln=%d}\n",
            entry.filename, entry.source_ln, entry.dest_ln)
    end
    result = result .. "    }\n"
    return result
end

function M.error(fmt, ...)
    local text = string.format(fmt, ...)
    local where = string.format("File %s, line %d\n", current_input.name, current_input.source_ln)
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
