-- blud.lua
blud_primary_target_name = nil

blud_module_code = [==[
local function dump(o)
    if type(o) == 'table' then
        local s = '{ '
        for k,v in pairs(o) do
            if type(k) ~= 'number' then k = '"'..k..'"' end
            s = s .. '['..k..'] = ' .. dump(v) .. ','
        end
        return s .. '} '
    else
        return tostring(o)
    end
end

blud              = {}
blud.public_env   = {}
blud.private_env  = { __index = blud.public_env }
blud.current_time = os.time()
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
    ADD_RULE = function(target, prerequisites, action)
        print("super_atom add_rule target = " .. dump(target) .. ": " .. dump(prerequisites))
        if action ~= nil then
            if target.ACTION then
                error("Target " .. target.NAME .. " already has an action")
            else
                target.ACTION = action
            end
        end
        local existing_prerequisites = target.PREREQUISITES or {}
        for _, dep in ipairs(prerequisites) do
            table.insert(existing_prerequisites, dep)
        end
        print("    add_rule, total prereq: " .. dump(existing_prerequisites))
        target.PREREQUISITES = existing_prerequisites
    end,
    APPLY_SPECIAL = function(atom, prerequisites)
        print("APPLY_SPECIAL " .. dump(atom))
        for _, prerequisite in ipairs(prerequisites) do
            
        end
    end,
    BUILD = function(target)
        print("BUILD('" .. target.NAME .. "')")
        if target.PARENT then print("PARENT('" .. dump(target.PARENT) .. "')") end
        if target.BUILDING then
            error("circular dependency on " .. target.NAME)
        end
        target.BUILDING = true
        target.BUILD_PREREQUISITES(target)
        local timestamp = blud.get_fs_timestamp(target.NAME)
        print("timestamp is " .. timestamp)
        if timestamp < blud.current_time then
            if target.ACTION then
                print("execute: '" .. target.ACTION .. "'")
                target:DO_ACTION()
                target:AFTER_ACTION()
            end
        end
        target.BUILDING = false
        return true   -- default is to pretend we successfully built it
    end,
    BUILD_PREREQUISITES = function(atom)
        print("BUILD_PREREQUISITES('" .. atom.NAME .. "')")
        local prerequisites = atom.PREREQUISITES;
        print("prereqs: " .. dump(prerequisites))
        if prerequisites then
            for _, prereq_name in ipairs(prerequisites) do
                prerequisite = atom.BIND(prereq_name)
--                prerequisite.PARENT = target
                prerequisite.BUILD(prerequisite, atom)
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
    AFTER_ACTION = function(target)
        return true
    end
}

setmetatable(blud.super_atom, blud.global)
blud.global.__index      = blud.global
blud.super_atom.__index  = blud.super_atom

blud.new_atom = function(atom_name)
    local atom = {}
    atom.NAME  = atom_name
    -- the initial metatable for an atom is the "super atom", which
    -- provides the default behavior
    return setmetatable(atom, blud.super_atom)
end
blud.is_special_atom = function(atom)
    return string.sub(atom.NAME, 1, 1) == "."
end

blud.set_callback = function(target, hook_name, callback_func)
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
        ADD_RULE = function(target, prerequisites, action)
            print(".AFTER add_rule target = " .. dump(target) .. ": " .. dump(prerequisites))
            getmetatable(target).ADD_RULE(target, prerequisites, action)
            for _, dep in ipairs(target.PREREQUISITES) do
                blud.set_callback(dep, "DO_ACTION", function (target,prerequistes,action)
                    return true
                    end)
            end
        end,
        DO_ACTION = function(target, prerequisites, action)
            local after = function()
                print("do after dammit!!!!!!!!!!!!!!!")
            end
print(".AFTER is setting callback")
            blud.set_callback(target.PARENT, "AFTER_ACTION", after)
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
        print(target.NAME .. " add rule")
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
    print("get_or_create_target('" .. target_name .. "')")
    local target = blud.TARGETS[target_name]
    if target == nil then
        target = blud.new_atom(target_name)
        blud.TARGETS[target_name] = target
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

function preprocess(get_line)
    local previous_indent   = 0
    local makeRulePattern = "^%s*(%S*%s*):.*$"

    while true do     -- for line in file:lines() do
        local line = get_line(false)
        if line == nil then break end
        if line:match(makeRulePattern) then
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
preprocess(buffered_line_io(file))
file:close()



if not blud_primary_target_name  then
    print("No target given to build")
end

blud_user_code = blud_user_code .. "\nblud.run_build(\"" .. blud_primary_target_name .. "\")\n"


print(blud_module_code)
print(blud_user_code);

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

