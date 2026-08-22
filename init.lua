-- init.lua: initial bootstrap code
--     need to get error handler set up before much else happens

local lua_sources = {}

function blud.register_lua_source(chunk_name, text, sourcemap)
    assert(type(chunk_name) == "string",
           "Lua source chunk name must be a string")
    assert(type(text) == "string",
           "Lua source text must be a string")
    assert(sourcemap == nil or type(sourcemap) == "table",
           "Lua source sourcemap must be a table or nil")

    local existing = lua_sources[chunk_name]
    if existing then
        assert(existing.text == text,
               string.format(
                   "Lua chunk %q is already registered with different text",
                   chunk_name))
        assert(existing.sourcemap == sourcemap,
               string.format(
                   "Lua chunk %q is already registered with a different sourcemap",
                   chunk_name))
        return
    end

    lua_sources[chunk_name] = {
        text = text,
        sourcemap = sourcemap,
    }
end

local function get_lua_sourcemap(chunk_name)
    local source_entry = lua_sources[chunk_name]
    if source_entry and source_entry.sourcemap then
        return source_entry.sourcemap
    end

    if chunk_name == blud.sourcemap_chunk_name then
        return blud.sourcemap
    end
end

function blud.resolve_lua_location(chunk_name, generated_ln)
    local sourcemap = get_lua_sourcemap(chunk_name)

    if sourcemap then
        for i = #sourcemap, 1, -1 do
            local entry = sourcemap[i]
            if entry.dest_ln <= generated_ln then
                local source_text
                if sourcemap.sources and entry.source_index then
                    source_text = sourcemap.sources[entry.source_index]
                end
                return entry.filename,
                       entry.source_ln + generated_ln - entry.dest_ln,
                       true,
                       source_text
            end
        end
    end

    local source_entry = lua_sources[chunk_name]
    return chunk_name,
           generated_ln,
           false,
           source_entry and source_entry.text
end

local function split_lua_error(err)
    if type(err) ~= "string" then
        return
    end

    local chunk_name, line_number, message =
        err:match('^%[string "(.-)"%]:(%d+):%s*(.*)$')
    if not chunk_name then
        chunk_name, line_number, message =
            err:match("^(.-):(%d+):%s*(.*)$")
    end

    if chunk_name then
        return chunk_name, tonumber(line_number), message
    end
end

function blud.format_lua_error(err, chunk_name)
    local reported_chunk_name, generated_ln, message = split_lua_error(err)
    if not reported_chunk_name then
        return tostring(err)
    end

    local filename, source_ln = blud.resolve_lua_location(
        chunk_name or reported_chunk_name,
        generated_ln
    )
    return string.format("%s:%d: %s", filename, source_ln, message)
end

function blud.load_lua_source(text, chunk_name, sourcemap)
    blud.register_lua_source(chunk_name, text, sourcemap)

    local chunk, err = load(text, chunk_name)
    if not chunk then
        err = blud.format_lua_error(err, chunk_name)
    end
    return chunk, err
end

function blud.load_lua_bytecode(bytecode, text, chunk_name, sourcemap)
    blud.register_lua_source(chunk_name, text, sourcemap)

    local chunk, err = load(bytecode, chunk_name)
    if not chunk then
        err = blud.format_lua_error(err, chunk_name)
    end
    return chunk, err
end

-- Helper function to return the text of a specific line from a string
-- @param source: The entire source string
-- @param line_number: The desired line number (1-based index)
-- @return: The text of the line (without newline characters), or nil if the line does not exist
local function get_line_from_source(source, line_number)
    local pos = 1  -- Start at the beginning of the string
    for i = 1, line_number - 1 do
        -- Find the position of the next newline
        pos = source:find("\n", pos, true)
        if not pos then
            return nil  -- If there are fewer lines than line_number, return nil
        end
        pos = pos + 1  -- Move the position after the newline
    end

    -- Now find the end of the line
    local line_end = source:find("\n", pos, true) or #source + 1  -- Either find next newline or the end of string
    return source:sub(pos, line_end - 1)  -- Return the line, without the newline character
end

-- Custom error handler for xpcall that iterates over the stack frames
function blud.error_handler(err)
    local compile_error_prefix = "BLUD_COMPILE_ERROR:"
    if type(err) == "string" and
       err:sub(1, #compile_error_prefix) == compile_error_prefix then
        return err
    end

    if blud.roots and blud.roots[1] and blud.why then
        pcall(blud.why.report)
    end

    -- must never die, so wrap it
    local ok, result = pcall(function()

            local lines = {}

            -- Add the error message itself
            table.insert(lines, "Error: " .. blud.format_lua_error(err))

            -- Iterate over the stack frames starting from the 3rd frame
            -- (skip error handler frame)
            local level = 3
            while true do
                -- Get source/line info ("Sl") and function name ("n")
                local info = debug.getinfo(level, "Sln")
                if not info then break end  -- Stop when no more frames

                local file_name = info.source
                local line_number = info.currentline
                local func_name = info.name or "[C function]"  -- Get the function name or indicate C function
                local source_entry = file_name and lua_sources[file_name]
                local sourcemap = file_name and get_lua_sourcemap(file_name)

                if (source_entry or sourcemap) and line_number > 0 then
                    local source_text
                    file_name, line_number, _, source_text =
                        blud.resolve_lua_location(file_name, line_number)

                    local src_line = source_text and get_line_from_source(
                        source_text,
                        line_number
                    )

                    -- Add the stack frame information along with the source line
                    if src_line then
                        table.insert(lines, string.format("  %s:%d --> %s", file_name, line_number, src_line))
                    else
                        table.insert(lines, string.format("  %s:%d", file_name, line_number))
                    end
                elseif info.what == "C" then
                    -- Add C function name and indicate it
                    table.insert(lines, string.format("  C function '%s'", func_name))
                else
                    -- Add the stack frame info without registered source code
                    table.insert(lines, string.format("  %s:%d in function '%s'", info.source, info.currentline, func_name))
                end

                level = level + 1
            end

            return table.concat(lines, "\n")
    end)
    if ok then return result end
    return debug.traceback(
        "error handler failed: " .. tostring(result) ..
        "\noriginal error: " .. tostring(err),
        2
    )
end
