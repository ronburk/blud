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

table.insert(package.loaders, 1, function(modname)
    local filename = modname .. ".lua"
    local source = CSTRGet(filename)
    if source == nil then
        return nil, "\n\tmodule '" .. modname .. "' not found in embedded strings"
    end

    local safe_name = "[" .. filename .. "]"
    blud.sources[safe_name] = source
    return assert(load(source, safe_name))
end)

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

blud.require("error.lua")

local function print_help()
    print([[Usage: blud [OPTION]... [TARGET]...

Options:
  -f FILE              Read FILE instead of bludfile.
  --lua FILE [ARG]...  Run FILE with embedded LuaJIT; pass remaining arguments.
  -d                    Start the interactive debugger.
  -B                    Rebuild targets regardless of timestamps.
  --why TARGET          Build normally, then explain TARGET's build decision.
  -n                    Print actions without executing them.
  -s, --silent,
      --quiet           Do not print actions before executing them.
  -W ATOM               Assume ATOM is newly changed.
  -h, --help            Show this help and exit.]])
end

function blud.parse_command_line()
    local debugger
    local options = {
        bludfile_path = "bludfile",
        debug = false,
        always_make = false,
        commandline_booleans = {},
    }
    local args = _G.COMMAND_LINE
    local i = 2     -- skip command-name
    while i <= #args do
        local arg = args[i]

        if arg == "-h" or arg == "--help" then
            print_help()
            os.exit(0)
        elseif arg == "-f" then
            i = i + 1
            if i <= #args then
                options.bludfile_path = args[i]
            end
        elseif arg == "--lua" then
            i = i + 1
            if i > #args then
                error("--lua requires a Lua file")
            end

            _G.arg = {}
            for j = i, #args do
                _G.arg[j - i] = args[j]
            end

            setmetatable(_G, nil)
            local chunk, load_error = loadfile(args[i])
            if not chunk then
                error(load_error, 0)
            end
            chunk()
            os.exit(0)
        elseif arg == "-d" then
            options.debug = true
            debugger = debugger or require("debugger")
            debugger.probe = debugger.real_probe
        elseif arg == "-B" then
            options.always_make = true
        elseif arg == "--why" then
            i = i + 1
            if i > #args then
                error("--why requires a target name")
            end
            if options.why_target_name then
                error("--why may be specified only once")
            end
            options.why_target_name = args[i]
        elseif arg == "-n" then
            options.commandline_booleans[".JUST_PRINT"] = true
        elseif arg == "-s" or arg == "--silent" or arg == "--quiet" then
            options.commandline_booleans[".SILENT"] = true
        elseif arg == "-W" then
            i = i + 1
            if i > #args then
                error("-W requires an atom name")
            end

            options.assume_new_names = options.assume_new_names or {}
            table.insert(options.assume_new_names, args[i])
        elseif arg:sub(1, 1) == "-" then
            error("unknown command-line option: " .. arg)
        else
            options.target_names = options.target_names or {}
            table.insert(options.target_names, arg)
        end
        i = i + 1
    end

    debugger = debugger or require("debugger")
    debugger.probe({func="<start>"})
    blud.command_line_options = options
end

blud.parse_command_line()

function get_bludfile_path()
    return blud.command_line_options.bludfile_path
end


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

-- blud.printf("luac_needs_building == %s", blud.luac_needs_building())

-- Example test
blud.require("blud.lua")
BLUD_EXIT(0)
