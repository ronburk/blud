local debugger = {}
local lua_debug = _G.debug

local debug_info
local source_cache = {}
local step_mode
local step_target_depth
local stopped_depth

local function normalize_source_name(info)
    local source = info.source or info.short_src or "<unknown>"

    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end

    if source:sub(1, 1) == "[" and source:sub(-1) == "]" then
        source = source:sub(2, -2)
    end

    return source
end

local function get_source_lines(source)
    if source_cache[source] then
        return source_cache[source]
    end

    local cstr_get = rawget(_G, "CSTRGet")
    if not cstr_get then
        return nil
    end

    local text = cstr_get(source)
    if not text then
        return nil
    end

    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        table.insert(lines, line)
    end

    source_cache[source] = lines
    return lines
end

local function call_depth(start_level)
    local depth = 0
    local level = start_level
    while lua_debug.getinfo(level, "f") do
        depth = depth + 1
        level = level + 1
    end
    return depth
end

local function print_current_line()
    if debug_info then
        local source = normalize_source_name(debug_info)
        local line = debug_info.currentline
        local lines = get_source_lines(source)

        print(string.format("%s:%d:", source, line))
        if lines and lines[line] then
            print(lines[line])
        else
            print("<source not available>")
        end
    end
end


local function print_backtrace()
    local frame = 0
    local level = 3

    while true do
        local info = lua_debug.getinfo(level, "nSl")
        if not info then
            break
        end

        local source = normalize_source_name(info)
        if not source:match("debugger%.lua$") then
            local name = info.name or "?"
            local line = info.currentline or -1
            print(string.format("#%d  %s at %s:%d", frame, name, source, line))
            frame = frame + 1
        end

        level = level + 1
    end
end

local function should_stop(depth)
    if step_mode == "step" then
        return true
    end

    if step_mode == "next" then
        return depth <= step_target_depth
    end

    return false
end

local function step_hook(event, line)
    if event == "line" then
        debug_info = lua_debug.getinfo(2)

        if normalize_source_name(debug_info):match("debugger%.lua$") then
            return
        end

        local depth = call_depth(2)
        if not should_stop(depth) then
            return
        end

        lua_debug.sethook()
        step_mode = nil
        step_target_depth = nil
        stopped_depth = depth
        print_current_line()
        debugger.interactive(">")
    end
end

local function custom_handler(command, arg)
    print("unknown debugger command: " .. tostring(command) .. " " .. tostring(arg))
end

function debugger.probe()
    return true
end

function debugger.real_probe(args)
    debug_info = lua_debug.getinfo(2)
    stopped_depth = call_depth(2)
    print_current_line()
    debugger.interactive(">")
end

function debugger.interactive(prompt, handler)
    handler = handler or custom_handler

    while true do
        io.write(prompt)
        local input = io.read()
        if not input then
            os.exit()
        end

        local command, arg = input:match("^(%S+)%s*(.*)")
        command = command or ""
        arg = arg or ""

        if command == "?" or command == "help" then
            print("q quit | c continue | s step | n next | bt backtrace | e <lua> eval | ? help")
        elseif command == "q" or command == "quit" then
            os.exit()
        elseif command == "c" or command == "continue" or command == "resume" then
            break
        elseif command == "bt" or command == "where" then
            print_backtrace()
        elseif command == "s" or command == "step" then
            step_mode = "step"
            lua_debug.sethook(step_hook, "l")
            break
        elseif command == "n" or command == "next" then
            step_mode = "next"
            step_target_depth = stopped_depth or 0
            if step_target_depth == 0 then
                step_mode = "step"
            end
            lua_debug.sethook(step_hook, "l")
            break
        elseif command == "e" or command == "eval" then
            local chunk, err = load(arg)
            if chunk then
                local status, result = pcall(chunk)
                if status then
                    print(result)
                else
                    print("Error during evaluation: " .. result)
                end
            else
                print("Compilation error: " .. err)
            end
        else
            handler(command, arg)
        end
    end
end

return debugger
