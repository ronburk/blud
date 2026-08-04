local debugger = {}
local lua_debug = _G.debug

local debug_info
local source_cache = {}
local step_mode
local step_target_depth
local stopped_depth
local paused_frames
local breakpoints = {}
local registered_operators
local operator_member_names
local instrumented_operators = {}

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

local function capture_paused_frames(start_level)
    local frames = {}
    local level = start_level

    while true do
        local info = lua_debug.getinfo(level, "nSluf")
        if not info then
            break
        end

        local source = normalize_source_name(info)
        if not source:match("debugger%.lua$") then
            local parameters = {}
            for index = 1, info.nparams or 0 do
                local name, value = lua_debug.getlocal(level, index)
                if name then
                    table.insert(parameters, {
                        name = name,
                        value = value,
                    })
                end
            end

            table.insert(frames, {
                name = info.name or "?",
                source = source,
                line = info.currentline or -1,
                what = info.what,
                parameters = parameters,
                is_vararg = info.isvararg,
            })
        end

        level = level + 1
    end

    return frames
end

local function operator_frame(member_name, implementation, self, arguments)
    local info = assert(
        lua_debug.getinfo(implementation, "Su"),
        "could not get debug information for operator member: " .. member_name
    )
    local parameters = {}

    for index = 1, info.nparams or 0 do
        local name = lua_debug.getlocal(implementation, index)
        if name then
            local value
            if index == 1 then
                value = self
            else
                value = arguments[index - 1]
            end

            table.insert(parameters, {
                name = name,
                value = value,
            })
        end
    end

    return {
        name = member_name,
        source = normalize_source_name(info),
        line = info.linedefined or -1,
        what = info.what,
        parameters = parameters,
        is_vararg = info.isvararg,
    }
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

local function find_operator_breakpoint(operator_name)
    for id = 1, #breakpoints do
        local breakpoint = breakpoints[id]
        if breakpoint and breakpoint.kind == "operator"
                and breakpoint.operator_name == operator_name then
            return id, breakpoint
        end
    end
end

local function stop_at_operator_breakpoint(
        id,
        breakpoint,
        member_name,
        implementation,
        self,
        arguments
    )
    print(string.format(
        "Breakpoint %d: operator %s, function %s",
        id,
        breakpoint.operator_name,
        member_name
    ))

    debug_info = assert(
        lua_debug.getinfo(implementation, "S"),
        "could not get debug information for operator member: " .. member_name
    )
    debug_info.currentline = debug_info.linedefined
    stopped_depth = call_depth(2)
    local caller_frames = capture_paused_frames(2)
    paused_frames = {
        operator_frame(member_name, implementation, self, arguments),
    }
    for _, frame in ipairs(caller_frames) do
        table.insert(paused_frames, frame)
    end
    print_current_line()
    debugger.interactive(">")
end

local function operator_wrapper(operator, member_name, implementation)
    return function(self, ...)
        local arguments = {
            n = select("#", ...),
            ...,
        }
        local breakpoint_id, breakpoint =
            find_operator_breakpoint(operator.name)
        if breakpoint_id then
            stop_at_operator_breakpoint(
                breakpoint_id,
                breakpoint,
                member_name,
                implementation,
                self,
                arguments
            )
        end
        return implementation(self, ...)
    end
end

local function instrument_operator(operator)
    if instrumented_operators[operator] then
        return
    end

    local id = find_operator_breakpoint(operator.name)
    if not id then
        return
    end

    instrumented_operators[operator] = true
    for _, member_name in ipairs(operator_member_names) do
        local implementation = operator[member_name]
        assert(type(implementation) == "function",
               "operator member is not a function: " .. member_name)
        operator[member_name] =
            operator_wrapper(operator, member_name, implementation)
    end
end

local function set_operator_breakpoint(operator_name)
    local id = find_operator_breakpoint(operator_name)
    if not id then
        table.insert(breakpoints, {
            kind = "operator",
            operator_name = operator_name,
        })
        id = #breakpoints
    end

    if registered_operators then
        local operator = registered_operators[operator_name]
        if operator then
            instrument_operator(operator)
        end
    end

    print(string.format("Breakpoint %d: operator %s", id, operator_name))
end


local function print_backtrace()
    for index, frame in ipairs(paused_frames or {}) do
        local name = frame.name

        if frame.what == "Lua" then
            local parameter_names = {}
            for _, parameter in ipairs(frame.parameters) do
                table.insert(parameter_names, parameter.name)
            end
            if frame.is_vararg then
                table.insert(parameter_names, "...")
            end
            name = name .. "(" .. table.concat(parameter_names, ", ") .. ")"
        end

        print(string.format(
            "#%d  %s at %s:%d",
            index - 1,
            name,
            frame.source,
            frame.line
        ))
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
        paused_frames = capture_paused_frames(2)
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

local escaped_bytes = {
    [7] = "\\a",
    [8] = "\\b",
    [9] = "\\t",
    [10] = "\\n",
    [11] = "\\v",
    [12] = "\\f",
    [13] = "\\r",
    [34] = "\\\"",
    [92] = "\\\\",
}

local function quote_string(value)
    local parts = {"\""}

    for index = 1, #value do
        local byte = value:byte(index)
        local escaped = escaped_bytes[byte]

        if escaped then
            table.insert(parts, escaped)
        elseif byte >= 32 and byte <= 126 then
            table.insert(parts, value:sub(index, index))
        else
            table.insert(parts, string.format("\\%03d", byte))
        end
    end

    table.insert(parts, "\"")
    return table.concat(parts)
end

local function format_string(value)
    if #value <= string_preview_length then
        return quote_string(value)
    end

    return quote_string(value:sub(1, string_preview_length))
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
            and key:match("^[A-Za-z_][A-Za-z0-9_]*$") then
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
            and key:match("^[A-Za-z_][A-Za-z0-9_]*$") then
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

local function environment_for_frame(frame)
    local parameter_values = {}
    local parameter_names = {}

    for _, parameter in ipairs(frame.parameters) do
        parameter_names[parameter.name] = true
        parameter_values[parameter.name] = parameter.value
    end

    return setmetatable({}, {
        __index = function(_, name)
            if parameter_names[name] then
                return parameter_values[name]
            end
            return _G[name]
        end,
    })
end

local function parse_explore_argument(arg)
    if arg == "" then
        return nil, nil, "explore requires a Lua expression"
    end

    local frame_number = 0
    local expression = arg

    if arg:sub(1, 1) == "#" then
        local number_text
        number_text, expression = arg:match("^#(%d+)%s+(.+)$")
        if not number_text then
            return nil, nil, "usage: x [#frame] <lua expression>"
        end
        frame_number = tonumber(number_text)
    end

    return frame_number, expression
end

function debugger.probe()
    return true
end

function debugger.real_probe(args)
    debug_info = lua_debug.getinfo(2)
    stopped_depth = call_depth(2)
    paused_frames = capture_paused_frames(2)
    print_current_line()
    debugger.interactive(">")
end

function debugger.register_operators(operators, member_names)
    assert(not registered_operators,
           "debugger operator members have already been registered")
    assert(type(operators) == "table",
           "debugger operator registry must be a table")
    assert(type(member_names) == "table",
           "debugger operator member list must be a table")

    registered_operators = operators
    operator_member_names = member_names

    for id = 1, #breakpoints do
        local breakpoint = breakpoints[id]
        if breakpoint then
            local operator = operators[breakpoint.operator_name]
            if operator then
                instrument_operator(operator)
            end
        end
    end
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
            print("q quit | c continue | s step | n next | bt backtrace | b <operator> break | e <lua> eval | x [#frame] <lua> explore | ? help")
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
        elseif command == "b" or command == "break" then
            local operator_name = arg:match("^(%S+)%s*$")
            if not operator_name then
                print("usage: b <operator_name>")
            else
                set_operator_breakpoint(operator_name)
            end
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
            local frame_number, expression, parse_error =
                parse_explore_argument(arg)
            if parse_error then
                print(parse_error)
            else
                local frame = paused_frames and paused_frames[frame_number + 1]
                if not frame then
                    print("no such frame: #" .. frame_number)
                else
                    local chunk, err = load("return " .. expression)
                    if chunk then
                        setfenv(chunk, environment_for_frame(frame))
                        local status, result = pcall(chunk)
                        if status then
                            explore(result, expression)
                        else
                            print("Error during evaluation: " .. result)
                        end
                    else
                        print("Compilation error: " .. err)
                    end
                end
            end
        else
            handler(command, arg)
        end
    end

    paused_frames = nil
end

return debugger
