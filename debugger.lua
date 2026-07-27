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

local function collect_entries(value)
    local entries = {}

    for key, child in next, value do
        table.insert(entries, {
            key = key,
            value = child,
            order = #entries + 1,
        })
    end

    local function key_group(key)
        local key_type = type(key)

        if key_type == "number" then
            return 1
        elseif key_type == "string" then
            return 2
        elseif key_type == "boolean" then
            return 3
        end

        return 4
    end

    table.sort(entries, function(a, b)
        local a_group = key_group(a.key)
        local b_group = key_group(b.key)

        if a_group ~= b_group then
            return a_group < b_group
        elseif a_group == 1 or a_group == 2 then
            return a.key < b.key
        elseif a_group == 3 then
            return not a.key and b.key
        end

        return a.order < b.order
    end)

    return entries
end

local string_preview_length = 80

local function format_string(value)
    if #value <= string_preview_length then
        return string.format("%q", value)
    end

    return string.format("%q", value:sub(1, string_preview_length))
        .. string.format("... (%d bytes)", #value)
end

local function format_value(value)
    local value_type = type(value)

    if value_type == "string" then
        return format_string(value)
    elseif value_type == "number" or value_type == "boolean" or value_type == "nil" then
        return tostring(value)
    elseif value_type == "table" then
        local count = 0
        for _ in next, value do
            count = count + 1
        end

        return string.format("table (%d %s)", count, count == 1 and "item" or "items")
    end

    return "<" .. value_type .. ">"
end

local function format_key(key)
    local key_type = type(key)

    if key_type == "string" and #key <= string_preview_length
            and key:match("^[%a_][%w_]*$") then
        return key
    elseif key_type == "string" then
        return "[" .. format_string(key) .. "]"
    elseif key_type == "number" or key_type == "boolean" then
        return "[" .. tostring(key) .. "]"
    end

    return "[<" .. key_type .. " key>]"
end

local function child_path(parent_path, key)
    local key_type = type(key)

    if key_type == "string" and #key <= string_preview_length
            and key:match("^[%a_][%w_]*$") then
        return parent_path .. "." .. key
    elseif key_type == "string" then
        return parent_path .. "[" .. format_string(key) .. "]"
    elseif key_type == "number" or key_type == "boolean" then
        return parent_path .. "[" .. tostring(key) .. "]"
    end

    return parent_path .. "[<" .. key_type .. " key>]"
end

local function explorer_frame(value, path)
    return {
        value = value,
        path = path,
        entries = type(value) == "table" and collect_entries(value) or nil,
    }
end

local function explore(root_value, root_expression)
    local stack = {explorer_frame(root_value, root_expression)}

    while true do
        local frame = stack[#stack]

        print(frame.path .. " = " .. format_value(frame.value))
        print()

        if frame.entries then
            for index, entry in ipairs(frame.entries) do
                print(string.format("  %d  %s = %s", index, format_key(entry.key), format_value(entry.value)))
            end

            print()
            io.write("Select an item; Enter returns; q quits: ")
        else
            io.write("This value cannot be expanded; press Enter to return or q to quit: ")
        end

        local input = io.read()
        if not input then
            os.exit()
        elseif input == "" then
            if #stack == 1 then
                return
            end
            table.remove(stack)
        elseif input == "q" or input == "quit" then
            return
        elseif input == "?" or input == "help" then
            print("number descend | Enter return | q quit | ? help")
        elseif frame.entries and input:match("^%d+$") then
            local entry = frame.entries[tonumber(input)]
            if entry then
                table.insert(stack, explorer_frame(entry.value, child_path(frame.path, entry.key)))
            else
                print("no such item: " .. input)
            end
        else
            print("invalid explorer command: " .. input)
        end
    end
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
            print("q quit | c continue | s step | n next | bt backtrace | e <lua> eval | x <lua> explore | ? help")
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
        elseif command == "x" or command == "explore" then
            if arg == "" then
                print("explore requires a Lua expression")
            else
                local chunk, err = load("return " .. arg)
                if chunk then
                    local status, result = pcall(chunk)
                    if status then
                        explore(result, arg)
                    else
                        print("Error during evaluation: " .. result)
                    end
                else
                    print("Compilation error: " .. err)
                end
            end
        else
            handler(command, arg)
        end
    end
end

return debugger
