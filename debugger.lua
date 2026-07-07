local util     = require("util")
local debugger = {}
local lua_debug = _G.debug

local debug_info

local function print_current_line()
    if debug_info then
        local source = debug_info.short_src
        local line = debug_info.currentline
        print(string.format("Stepping into %s at line %d", source, line))
    end
end

local function step_hook(event, line)
    if event == "line" then
        debug_info = lua_debug.getinfo(2)

        if debug_info.short_src:match("debugger%.lua$") then
            return
        end

        print_current_line()
        lua_debug.sethook() -- Remove the hook after printing
    end
end

-- Example custom command handler
local function custom_handler(command, arg)
    print("Custom handler received command: " .. command .. " with argument: " .. arg)
end

function debugger.probe()
    return true
end

function debugger.real_probe(args)
    util.printf("%s", args.func)
    debugger.interactive(">")
end

function debugger.interactive(prompt, handler)
    handler = handler or custom_handler

    local debug_active = true
    while debug_active do
        io.write(prompt)
        local input = io.read()
        local command, arg = input:match("^(%S+)%s*(.*)")

        if command == "quit" then
            os.exit()
        elseif command == "resume" then
            break
        elseif command == "eval" then
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
        elseif command == "step" then
            lua_debug.sethook(step_hook, "l")
            break -- Step out of the debugger to execute the next line
        else
            handler(command, arg)
        end
    end
end


return debugger
