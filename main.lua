blud.register_lua_source("[init.lua]", CSTRGet("init.lua"))
blud.register_lua_source("[main.lua]", CSTRGet("main.lua"))

-- let's catch bad global references
setmetatable(_G, {
    __index = function(_, key)
        error("Attempt to access undefined global variable: " .. tostring(key), 2)
    end
})


function blud.printf(fmt, ...)
    print(string.format(fmt, ...))
end




local function load_embedded_lua(filename)
    local source = CSTRGet(filename)
    if source == nil then
        return nil
    end

    local bytecode = assert(
        CSTRGetCompiled(filename),
        "no compiled code for embedded Lua source: " .. filename
    )
    local safe_name = "[" .. filename .. "]"
    return assert(blud.load_lua_bytecode(
        bytecode,
        source,
        safe_name
    ))
end

table.insert(package.loaders, 1, function(modname)
    local prefix = "blud."
    if modname:sub(1, #prefix) ~= prefix then
        return nil
    end

    local filename = modname:sub(#prefix + 1) .. ".lua"
    local chunk = load_embedded_lua(filename)
    if chunk == nil then
        return nil, "\n\tmodule '" .. modname .. "' not found in embedded strings"
    end

    return chunk
end)

require("blud.error")

local function print_help()
    print([[Usage: blud [OPTION]... [TARGET]...

Options:
  -f FILE              Read FILE instead of bludfile.
  --lua FILE [ARG]...  Run FILE with embedded LuaJIT; pass remaining arguments.
  -d                    Start the interactive debugger.
  -B                    Rebuild targets regardless of timestamps.
  --why TARGET          Build normally, then explain TARGET's build decision.
  -n                    Print actions without executing them.
  --trace              Annotate actions with their associated targets.
  -s, --silent,
      --quiet           Do not print actions before executing them.
  -W ATOM               Assume ATOM is newly changed.
  -v                    Show blud and LuaJIT versions and exit.
  -?, -h, --help        Show this help and exit.]])
end

local function parse_command_line(args)
    local debugger
    local options = {
        bludfile_path = "bludfile",
        debug = false,
        always_make = false,
        commandline_booleans = {},
    }
    local i = 2     -- skip command-name
    while i <= #args do
        local arg = args[i]

        if arg == "-?" or arg == "-h" or arg == "--help" then
            print_help()
            os.exit(0)
        elseif arg == "-v" then
            print("blud build " .. blud.build_id)
            print(jit.version)
            os.exit(0)
        elseif arg == "-f" then
            i = i + 1
            if i > #args then
                error("-f requires a bludfile")
            end
            options.bludfile_path = args[i]
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
            debugger = debugger or require("blud.debugger")
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
        elseif arg == "--trace" then
            options.trace = true
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
            local macro = require("blud.macro").match_macro_assign(arg)
            if macro then
                print("command-line macro assignment: " .. arg)
            else
                options.target_names = options.target_names or {}
                table.insert(options.target_names, arg)
            end
        end
        i = i + 1
    end

    debugger = debugger or require("blud.debugger")
    debugger.probe({func="<start>"})
    return options
end

blud.command_line_options = parse_command_line(_G.COMMAND_LINE)

function get_bludfile_path()
    return blud.command_line_options.bludfile_path
end


function blud.luac_needs_building()
    local bludfile_path = get_bludfile_path()
    local luac_path = bludfile_path .. ".luac"
    local blud_exe_path = get_executable_path()
    assert(blud_exe_path ~= nil)
    local dircache = require("blud.dircache")
    local blud_exe_timestamp = dircache.get_timestamp(blud_exe_path)
    local bludfile_timestamp = dircache.get_timestamp(bludfile_path)
    local luac_timestamp     = dircache.get_timestamp(luac_path)

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
require("blud.blud")
BLUD_EXIT(0)
