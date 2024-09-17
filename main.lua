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
local function custom_error_handler(err)
    local lines = {}

    print(debug.traceback())
    -- Add the error message itself
    table.insert(lines, "Error: " .. tostring(err))

    -- Iterate over the stack frames starting from the 2nd frame (skip error handler frame)
    local level = 2
    while true do
        -- Get source/line info ("Sl") and function name ("n")
        local info = debug.getinfo(level, "Sln")
        if not info then break end  -- Stop when no more frames

        -- Check if the source is in main.sources (i.e., it's a dynamically loaded chunk)
        local file_name = info.source
        local line_number = info.currentline
        local func_name = info.name or "[C function]"  -- Get the function name or indicate C function

        if file_name and main.sources[file_name] and line_number > 0 then
            -- Get the specific line from the source code
            local source = main.sources[file_name]
            local src_line = get_line_from_source(source, line_number)

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
            -- Add the stack frame info without source code if not in main.sources
            table.insert(lines, string.format("  %s:%d in function '%s'", info.source, info.currentline, func_name))
        end

        level = level + 1
    end

    return table.concat(lines, "\n")
end

main = {}
main.sources = {}


-- Helper function that does the actual work of loading and running the Lua chunk
local function load_and_run(name)
    local source = CSTRGet(name)
    if source == nil then error("no such internal file: " .. name) end

    local safe_name = "[" .. name .. "]"
    main.sources[safe_name] = source

    local chunk, load_err = load(source, safe_name)
    if not chunk then
        error(load_err)  -- Raise the syntax error to be caught by xpcall
    end

    return chunk()  -- Run the chunk (runtime errors will also be caught by xpcall)
end

-- .require now only handles error handling via xpcall
function main.require(name)
    local status, result = xpcall(function() return load_and_run(name) end, custom_error_handler)
    
    if not status then
        print(result)  -- Print the full stack trace and error message with source code
        return nil, result
    end
    
    return result
end

-- Example test
main.require("blud.lua")
