-- blud.lua

function template(str, values)
    return (str:gsub("{(.-)}", function(key)
        return values[key] or "{" .. key .. "}"
    end))
end



blud_primary_target_name = ""

blud_module_code = [==[
local function dump(o)
    if type(o) == 'table' then
        local s = '{ '
        for k,v in pairs(o) do
            if type(k) ~= 'number' then k = '"'..k..'"' end
            if v ~= "__index" then
            s = s .. '['..k..'] = ' .. dump(v) .. ','
            end
        end
        return s .. '} '
    else
        return tostring(o)
    end
end

blud              = {}
blud.public_env   = {}
blud.private_env  = { __index = blud.public_env }
blud.match_macro_assign = function(line)
    local operators = {
        ["="]   = true,
        [":="]  = true,
        ["+="]  = true,
    }
--    print("match_macro_assign(\"" .. line .. "\")")
    local pattern = "^(%a+)%s*([=+:]+)%s*(.*)$"
    macro_name, operator, remainder = line:match(pattern)
    if macro_name and operator then
        if operators[operator] == true then
            return macro_name, operator, remainder
        end
    end
    return nil
end

blud.lines        = function (str)
    local pos = 1
    return function()
        if pos > #str then return nil end
        local start, stop, line = str:find("([^\r\n]*)[\r\n]?", pos)
        pos = stop + 1
        return line
    end
end

blud.get_macro_args = function (text, pos)
    
end

blud.get_macro_call = function (text, pos)
    local macro = nil
    local char = text:sub(pos, 1)
    if char == '(' then
        local pos, args = blud.get_macro_args(text, pos)
        macro = { name=args[0], args = args }
    else
        macro = { name=char, args = {} }
    end
    return pos, macro
end

blud.macro_expand = function (text)
    local result = ""
    local pos    = 1
    local max_pos= #text
    while pos <= max_pos do
        local char = text:sub(pos, 1)
        if char == '$' and pos < max_pos then
            local macro_name = nil
            pos  = pos + 1
            char = text:sub(pos, 1)
            if char == '$' then result = result .. char
            elseif char == '(' then
            end
        else
            result = result .. char
        end
    end
    return result
end
blud.phase2_text  = ""
blud.phase2_append= function(str)
    blud.phase2_text = blud.phase2_text .. str .. "\n"
end
blud.phase3_text  = ""
blud.phase3_append= function(str)
    blud.phase3_text = blud.phase2_text .. str .. "\n"
end
blud.phase2       = function ()
    print(blud.phase2_text)
    for line in blud.lines(blud.phase2_text) do
        print("Line is: " .. line )
        local macro_name, operator, text = blud.match_macro_assign(line)
        if macro_name then
            print(macro_name .. operator .. text)
        end
    end
end
blud.current_time = os.time()
blud.shallow_copy = function (original)
    local copy = {}
    for key, value in pairs(original) do
        copy[key] = value
    end
    return copy
end
blud.dump_atom = function (atom)
    local str = atom.NAME .. " : "
    local prerequisites = atom.PREREQUISITES
    if prerequisites ~= nil then
        for key, value in pairs(prerequisites) do
            str = str .. " " .. value.NAME
        end
    end
    return str
end

-- define super atom (a metatable), which contains defaults for all atoms
blud.global = {
    -- BIND: associate an atom with an actual filename
    BIND  = function(atom)
        -- ???
        return atom
    end,
    }
blud.super_atom = {
    NAME = "",
    ADD_PREREQUISITE = function(target, prerequisite)
        print("ADD_PREREQUISITE(" .. target.NAME .. ", " .. prerequisite.NAME .. ")")
        local prerequisites = target.PREREQUISITES
        if prerequisites ~= nil then
            table.insert(prerequisites, prerequisite)
        else
            target.PREREQUISITES = { prerequisite }
        end
        if target.ATTRIBUTE == true then
            local target_copy = blud.shallow_copy(target)
            target_copy.ATTRIBUTE_TARGET = prerequisite
            setmetatable(target_copy, getmetatable(prerequisite))
            target_copy.__index = target_copy
            setmetatable(prerequisite, target_copy)
        end
    end,
    ADD_RULE = function(target, prerequisites, action)
        print("super_atom ADD_RULE target = " .. dump(target) .. ": " .. dump(prerequisites))
        if type(action) == 'string' and action ~= '' then
            if target.ACTION then
                error("Target " .. target.NAME .. " already has an action: " .. target.ACTION)
            else
                target.ACTION = action
            end
        end
        if prerequisites ~= nil then
            for _, prerequisite in ipairs(prerequisites) do
                target.ADD_PREREQUISITE(target, prerequisite)
            end
        end
    end,
    APPLY_SPECIAL = function(atom, prerequisites)
        print("APPLY_SPECIAL " .. dump(atom))
        for _, prerequisite in ipairs(prerequisites) do
            
        end
    end,
    BUILD = function(target)
        print("BUILD('" .. blud.dump_atom(target) .. "')")
        if target.PARENT then print("PARENT('" .. blud.dump_atom(target.PARENT) .. "')") end
        if target.BUILDING == true then
            error("circular dependency on " .. target.NAME)
        end
        target.BUILDING = true
        target.BUILD_PREREQUISITES(target)
        local timestamp = blud.get_fs_timestamp(target.NAME)
        print("timestamp is " .. timestamp)
        if timestamp < blud.current_time then
            if target.ACTION then
                print("execute: '" .. target.ACTION .. "'")
--                print(" meta is " .. dump(getmetatable(target)))
                target:DO_ACTION()
            end
        end
        target.BUILDING = false
        return true   -- default is to pretend we successfully built it
    end,
    BUILD_PREREQUISITES = function(atom)
        print("BUILD_PREREQUISITES('" .. blud.dump_atom(atom) .. "')")
        local prerequisites = atom.PREREQUISITES;
--        print("prereqs: " .. dump(prerequisites))
        if prerequisites then
            for _, prereq_name in ipairs(prerequisites) do
                prerequisite = atom.BIND(prereq_name)
                prerequisite.PARENT = atom
                prerequisite.BUILD(prerequisite)
            end
        end

    end,
    DO_ACTION = function(target)
        print("DO_ACTION in super atom for " .. target.NAME)
        status, exit_code = os.execute(target.ACTION)
        assert(status)
        if exit_code then
            error("command failed: " .. target.ACTION)
        end
    end,
}

setmetatable(blud.super_atom, blud.global)
blud.global.__index      = blud.global
blud.super_atom.__index  = blud.super_atom

blud.new_atom = function(atom_name)
    local atom = {}
    -- atom must always have a name
    atom.NAME  = atom_name
    -- atom must always have a prerequisite list, even if it is empty
    -- this guarantees prerequisites are not inherited
    atom.PREREQUISITES = {}
    -- the initial metatable for an atom is the "super atom", which
    -- provides the default behavior
    return setmetatable(atom, blud.super_atom)
end
blud.is_special_atom = function(atom)
    return string.sub(atom.NAME, 1, 1) == "."
end

blud.set_callback = function(target, hook_name, callback_func)
print("set_callback(" .. target.NAME .. ", " .. hook_name .. ")")
    -- make new metatable whose metatable is target metatable
    local new_meta      = setmetatable({}, getmetatable(target))
    new_meta.__index    = new_meta
    -- new metatable will call callback_func for this particular hook
    new_meta[hook_name] = callback_func
    -- finally, insert new metatable before target's metatable
    setmetatable(target, new_meta)
end

blud.TARGETS = {
    [ ".AFTER" ] = {
        NAME = ".AFTER",
        ATTRIBUTE = true,
        DO_ACTION = function(target, prerequisites, action)
            local after = function()
                status, exit_code = os.execute(target.ATTRIBUTE_TARGET.ACTION)
            end
            blud.set_callback(target.PARENT, "DO_ACTION", after)
            return true
        end
    }
}

for atom_name, atom in pairs(blud.TARGETS) do
    setmetatable(atom, blud.super_atom)
end

blud.get_fs_timestamp = function (filepath)
    local command = string.format("stat -c %%Y '%s' 2>/dev/null", filepath)
    local pipe = io.popen(command, "r")
    local output = pipe:read("*a")
    pipe:close()

    -- Convert the timestamp to a number
    local timestamp = tonumber(output)
    if not timestamp then
        print("Failed to get timestamp for file: " .. filepath)
        timestamp = 0
    end
    return timestamp
end

blud.add_rule = function(target, prerequisites, action)
    print("add_rule('" .. target.NAME .. "' :" .. #prerequisites .. ")")
    if action ~= nil then
        if target.ACTION then
            error("Target " .. target.NAME .. " already has an action")
        else
            target.ACTION = action
        end
    end
    local prerequisites = target.PREREQUISITES or {}
    for _, dep in ipairs(prerequisites) do
        print("    ." .. dep)
        table.insert(prerequisitess, dep)
    end
    target.PREREQUISITES = prerequisites
end

blud.add_rules = function(targets, prerequisites, action)
print("blud.add_rules targets = " .. dump(targets) .. ": " .. dump(prerequisites))

    local prereq_atoms = {}
    for _, prereq_name in ipairs(prerequisites) do
        local prerequisite = blud.get_or_create_target(prereq_name)
        table.insert(prereq_atoms, prerequisite)
    end
    for _, target_name in ipairs(targets) do
        local target = blud.get_or_create_target(target_name)
        target.ADD_RULE(target, prereq_atoms, action)
    end
end


blud.build = function(target, parent_atom)
    print("[[[[[[[[[build " .. target.NAME .. "]]]]]]]]")
    blud.global.BIND(target)
    target.PARENT = parent_atom
    target:BUILD_PREREQUISITES()
    return target:BUILD()
end

blud.get_or_create_target = function(target_name)
    local target = blud.TARGETS[target_name]
    if target == nil then
        target = blud.new_atom(target_name)
        blud.TARGETS[target_name] = target
        blud.PREREQUISITES = {}
    end
    return target
end

-- build
blud.run_build = function(primary_target)
    local targets = {}
--    print("blud " .. primary_target)
    table.insert(targets, blud.get_or_create_target(primary_target))
--    print("before for: Type of blud.build:", type(blud.build)) 
    for _, target in ipairs(targets) do
        target:BUILD()
    end
end

]==]

blud_user_code = ""


-- returns generator that lets you read/peek one line at a time from the file
function buffered_line_io(file)
    local current_line; --  = file:read("*l")  -- Read the first line to prime the generator
    local has_peeked   = false
    local peek_line    = nil

    return function(peek)
        if peek then
            if has_peeked then
                return peek_line  -- Return the peeked line without advancing
            else
                peek_line  = file:read("*l")
                has_peeked = true
                return peek_line
            end
        else
            if has_peeked then    -- We've peeked, now consume that line
                has_peeked   = false
                current_line = peek_line
                peek_line    = nil
            else                -- No peek happened, move to the next line
                current_line = file:read("*l")
            end
            return current_line
        end
    end
end

function calculate_indent(line)
    if line == nil then return 0 end
    local indent = 0
    for i = 1, #line do
        local char = line:sub(i, i)
        if char == ' ' then
            indent = indent + 1
        elseif char == '\t' then
            indent = indent + 4
        else
            break
        end
    end
--    print("indent of '" .. line .. "' = " .. indent);
    return indent
end

function atoms_to_string(atoms)
    local result = ""
    for _, name in ipairs(atoms) do
        if result ~= "" then result = result .. ", " end
        result = result .. name
    end
    return result
end

function line_is_lua(line)
    local result     = true
    local keywords   = {
        ["do"]       = true,
        ["else"]     = true,
        ["elseif"]   = true,
        ["end"]      = true,
        ["for"]    = true,
        ["function"] = true,
        ["if"]       = true,
        ["local"]    = true,
        ["repeat"] = true,
        ["then"]   = true,
        ["until"]  = true,
        ["while"]  = true,
    }
    local first_word = line:match("^%a+")
    if first_word ~= nil then
        if keywords[first_word] == nil then
            result = false
        end
    end
    return result
end

function match_macro_assign(line)
    local operators = {
        ["="]   = true,
        [":="]  = true,
        ["+="]  = true,
    }
--    print("match_macro_assign(\"" .. line .. "\")")
    local pattern = "^(%a+)%s*([=+:]+)%s*(.*)$"
    macro_name, operator, remainder = line:match(pattern)
    if macro_name and operator then
        if operators[operator] == true then
            return macro_name, operator, remainder
        end
    end
    return nil
end

function lua_quote(str)
    -- Escape backslashes and double quotes
    str = str:gsub("\\", "\\\\"):gsub('"', '\\"')
    
    -- Replace special characters
    str = str:gsub("\n", "\\n")
            :gsub("\r", "\\r")
            :gsub("\t", "\\t")
            :gsub("\b", "\\b")
            :gsub("\f", "\\f")
    
    -- Wrap the string in double quotes
    return '"' .. str .. '"'
end

function emit_macro_assign(macro_name, operator, remainder)
    local variables = {
        macro_name = lua_quote(macro_name),
        operator   = lua_quote(operator),
        remainder  = lua_quote(remainder)
        }
    local script = [[
blud.macro_assign({macro_name}, {operator}, {remainder})
]]
    local var =  script:gsub("{(.-)}", variables)
    print(var)
end

function leading_keyword(line)
    local result = nil
    local keywords   = {
        ["do"]       = true,
        ["else"]     = true,
        ["elseif"]   = true,
        ["end"]      = true,
        ["for"]      = true,
        ["function"] = true,
        ["if"]       = true,
        ["local"]    = true,
        ["repeat"]   = true,
        ["until"]    = true,
        ["while"]    = true,
    }

    local keyword = line:match("^%a+")
    if keyword == "local" and line:match("local%s+function%s+") then
        keyword = "function"
    end
    if keywords[keyword] then result = keyword end
    return result
end

function syntax_error(line_number, format_string, ...)
    local args = {...}
    local message = format_string:gsub("#(%d+)", function(n)
        return tostring(args[tonumber(n)])
    end)
    error("Line " .. line_number .. ": " .. message)
end

-- handle a Lua line that might have embedded make code
-- ??? does not handle embedded $(name a b "c" "d()")
function phase1_embedded_make(line)
    local code = line:match("^%s*$ (.*)$")
    if code then
        line = "blud.phase2_append(" .. lua_quote(code) .. ")"
    end
    return line
end

function phase1_pass(get_line)
    local line_number   = 0
    local text          = ""
    local open_keyword  = nil
    while true do
        line_number = line_number + 1
        local line = get_line(false)
        if line == nil then break end -- end of file
        local keyword = leading_keyword(line)
        if not keyword then
            if open_keyword then   -- copying Lua code ??? handle embedded make code
                line = phase1_embedded_make(line)
            else -- copying non-Lua code
                line = "blud.phase2_append(" .. lua_quote(line) .. ")"
            end
        elseif keyword == "do" or keyword == "function" or keyword == "if" or keyword == "repeat" then
            if open_keyword then syntax_error(line_number, "already inside '#1'", open_keyword) end
            open_keyword = keyword
        elseif keyword == "end" then
            if not open_keyword then syntax_error(line_number, "Unexpected 'end'") end
            open_keyword = nil
        elseif keyword == "elseif" or keyword == "else" then
            if open_keyword ~= "if" and open_keyword ~= "elseif" then
                syntax_error(line_number, "Unexpected '#1' doesn't match open '#2'", keyword, open_keyword)
            else
                open_keyword = keyword
            end
        else
            line =  "blud.phase2_append(" .. lua_quote(line) .. ")"
        end
        text = text .. line .. "\n"
    end
    return text
end


function preprocess(get_line)
    local previous_indent   = 0

    while true do     -- for line in file:lines() do
        local line = get_line(false)
        if line == nil then break end
        local macro_name, operator, remainder = match_macro_assign(line)
        if macro_name then
            emit_macro_assign(macro_name, operator, remainder)
        else
        end
        if false then
        if not line_is_lua(line) then
            blud_user_code = blud_user_code .. "do -- " .. line .. "\n"
            local targets, prerequisites = process_make_rule(line) 
            local indent = calculate_indent(line)
            local action = ""
            while calculate_indent(get_line(true)) > indent do
                action = action .. get_line(false) .. "\n"
            end
            blud_user_code = blud_user_code .. "    blud.add_rules(targets, prerequisites, "
            if action == nil then
                blud_user_code = blud_user_code .. "nil)\n"
            else
                blud_user_code = blud_user_code .. "[[" .. action .. "]])\n"
            end
            
            blud_user_code = blud_user_code .. "end "
        else
            blud_user_code = blud_user_code .. line .. '\n'
        end
        end
    end
end

function process_make_rule(line)
    local targets       = {}
    local prerequisites = {}

    -- Split the line at the colon
    local target_part, prerequisite_part = line:match("^%s*(.-)%s*:%s*(.*)")

    -- Check and split the target part into paths
    blud_user_code = blud_user_code .. "    local targets = { "
    for target in target_part:gmatch("%S+") do
        blud_primary_target_name = blud_primary_target_name or target
        table.insert(targets, target)
        blud_user_code = blud_user_code .. '"' .. target .. '"'
    end
    blud_user_code = blud_user_code .. " }\n"

    -- Check and split the prerequisite part into paths
    blud_user_code = blud_user_code .. "    local prerequisites = { "
    for prerequisite in prerequisite_part:gmatch("%S+") do
        table.insert(prerequisites, prerequisite)
        blud_user_code = blud_user_code .. '"' .. prerequisite .. '"'
    end
    blud_user_code = blud_user_code .. " }\n"

--[=[
    local code = [[    blud.add_dependents(targets, prerequisites)
]]

    for _, target in ipairs(targets) do
        local atom_list = ""
        for _, prerequisite in ipairs(prerequisites) do
            atom_list = atom_list .. "," .. prerequisite
        end
        code = code:gsub("{target}", target);
        code = code:gsub("{atom_list}", atom_list);
        blud_user_code = blud_user_code .. code
    end
    ]=]

    return targets, prerequisites
end


--[[
local file = io.open("blud", "r")
assert(file)
local blud_file_text = file:read("*a")
file:close()
]]

file = io.stdin
--preprocess(buffered_line_io(file))
local str = phase1_pass(buffered_line_io(file))
file:close()
print(blud_module_code)
print(str)
print("blud.phase2()\n")



if not blud_primary_target_name  then
    print("No target given to build")
end

blud_user_code = blud_user_code .. "\nblud.run_build(\"" .. blud_primary_target_name .. "\")\n"


--print(blud_user_code);

--[[
function lines_length(input, line_number)
    if line_number >= 1 then
        local current_line = 1
        local position = 1

        -- Repeat finding new lines until the desired line
        while true do
            if current_line == line_number then
                return position
            end
            local start_pos, end_pos = string.find(input, "\n", position)
            if not start_pos then
                break  -- No more newlines found
            end
            current_line = current_line + 1
            position     = end_pos + 1
        end
    end
    return nil  -- Line number does not exist in the input
end


function parse_blud_file_text(source_text)
    local lua_text  = ""
    local func, error_message = loadstring(source_text)
    local line, message = error_message:match(":(%d+):%s*(.*)")
    if error_message then
        print("line " .. line .. ": " .. message)
        assert(false)
    end
end
parse_blud_file_text(blud_file_text)
assert(false)
]]

--[[
function report_error(error_message, code)
    print("Error ", error_message)
   -- Extracting the line number from the error message
    local lineNumber = tonumber(error_message:match(":(%d+):"))
    if lineNumber then
        -- Splitting the code into lines and printing the problematic line
        local lines = {}
        for line in code:gmatch("([^\n]*)\n?") do
            table.insert(lines, line)
        end
        print("Error at line", lineNumber, ":", lines[lineNumber])
    end

end


local program = blud_module_code .. blud_user_code
local func, err = loadstring(program)
print("back from loadstring")
if func then
    status, err = pcall(func)
    if not status then
        report_error(err, program);
    end
else
    report_error(err, program);
end
]]

