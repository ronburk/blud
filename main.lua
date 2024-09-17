main = {}
main.sources = {}

-- Custom error handler for xpcall
local function custom_error_handler(err)
    local trace = debug.traceback(err, 2)
    local lines = {}
    for line in trace:gmatch("[^\n]+") do
        -- Check if the line contains a reference to a chunk in main.sources
        local file_name, line_number = line:match("%[(.-)%]:(%d+)")
        if file_name and main.sources["[" .. file_name .. "]"] then
            local source = main.sources["[" .. file_name .. "]"]
            local src_line = source:match("(.-\n)", tonumber(line_number))
            if src_line then
                line = line .. " --> " .. src_line:gsub("%s*$", "")  -- Add the source line to the trace
            end
        end
        table.insert(lines, line)
    end
    return table.concat(lines, "\n")
end

function main.require(name)
    local source = CSTRGet(name)
    if source == nil then error("no such internal file: " .. name) end
    local safe_name = "[" .. name .. "]"
    main.sources[safe_name] = source
    local chunk = assert(load(source, safe_name))
    
    -- Execute the chunk using xpcall with a custom error handler
    local status, result = xpcall(chunk, custom_error_handler)
    
    if not status then
        print(result)  -- Print the traceback with source lines
        return nil, result
    end
    return result
end


main.require("blud.lua")

