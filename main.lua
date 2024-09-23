-- let's catch bad global references
setmetatable(_G, {
    __index = function(_, key)
        error("Attempt to access undefined global variable: " .. tostring(key), 2)
    end
})


function blud.printf(fmt, ...)
    print(string.format(fmt, ...))
end




blud.sources = {}
blud.sources["[main.lua]"] = CSTRGet("main.lua")

-- .require now only handles error handling via xpcall
function blud.require(name)
    local source = CSTRGet(name)
    if source == nil then error("no such internal file: " .. name) end

    local safe_name = "[" .. name .. "]"
    blud.sources[safe_name] = source

    local chunk, load_err = load(source, safe_name)
    if not chunk then
        error(load_err)  -- Raise the syntax error to be caught by xpcall
    end

    return chunk()  -- Run the chunk (runtime errors will also be caught by xpcall)
end

function get_bludfile_path()
    local path = "bludfile"
    local args = COMMAND_LINE
    local option = "-f"
    for i = 1, #args do
        if args[i] == option then
            -- Check if there's a next argument to be the value
            if i < #args then
                return args[i + 1]
            else
                return path
            end
        end
    end
    return path
end


print("start executing phase 1")
function blud.luac_needs_building()
    local bludfile_path = get_bludfile_path()
    local luac_path = bludfile_path .. ".luac"
    local blud_exe_path = get_executable_path()
    assert(blud_exe_path ~= nil)
    local blud_exe_timestamp = get_path_timestamp(blud_exe_path)
    local bludfile_timestamp = get_path_timestamp(bludfile_path)
    local luac_timestamp     = get_path_timestamp(luac_path)

    local luac_needs_building = true
    if bludfile_timestamp ~= nil and luac_timestamp ~= nil then
        if blud_exe_timestamp < bludfile_timestamp and blud_exe_timestamp < luac_timestamp then
            if bludfile_timestamp < luac_timestamp then
                luac_needs_building = false
            end
        end
    end
    return luac_needs_building
end

blud.printf("luac_needs_building == %s", blud.luac_needs_building())

-- Example test
blud.require("blud.lua")
