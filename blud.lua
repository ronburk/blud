-- blud.lua
blud_primary_target_name = nil

blud_module_code = [[
blud              = {}
blud.public_env   = {}
blud.private_env  = { __index = blud.public_env }
blud.current_time = os.time()
blud.TARGETS = {}
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

blud.add_raw_dependents = function(targets, string_list)
    for _, target_name in ipairs(targets) do
        local target = blud.TARGETS[target_name]
        if target == nil then
            target = {}
            blud.TARGETS[target_name] = target
        end
        local raw_dependents = target.RAW_DEPENDENTS or {}
        for _, dep in ipairs(string_list) do
            table.insert(raw_dependents, dep)
        end
        target.RAW_DEPENDENTS = raw_dependents
    end
end
blud.add_recipe = function(targets, recipe)
    assert(targets)
    assert(recipe)
    print(" add recipe " .. recipe)
    for _, target_name in ipairs(targets) do
        local target = blud.TARGETS[target_name]
        assert(target ~= nil)
        print(" add recipe " .. recipe .. "\nto target: " .. target_name)
        target.RECIPE = recipe
    end
end
blud.build = function(atom_name)
    print("build " .. atom_name)
    local timestamp = blud.get_fs_timestamp(atom_name)
    print("timestamp is " .. timestamp)
    local atom = blud.TARGETS[atom_name]
    if atom == nil then error("Unknown target: " .. atom_name) end
    if timestamp < blud.current_time then
        print(" execute recipe " .. atom.RECIPE)
        if atom.RECIPE then
            status, exit_code = os.execute(atom.RECIPE)
            assert(status)
            if exit_code then
                error("command failed: " .. atom.RECIPE)
            end
        end
    end
end
blud.run_build = function(primary_target)
    local targets = {}
    print("blud " .. primary_target)
    table.insert(targets, primary_target)
    print("before for: Type of blud.build:", type(blud.build)) 
    for _, target in ipairs(targets) do
        print("Type of blud.build:", type(blud.build)) 
        blud.build(target)
    end
end
]]

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
            local recipe = ""
            while calculate_indent(get_line(true)) > indent do
                recipe = recipe .. get_line(false) .. "\n"
            end
            if recipe ~= "" then
                local code = "    blud.add_recipe(targets,\n[[\n" .. recipe .. "]])\n"
                blud_user_code = blud_user_code .. code
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

    local code = [[    blud.add_raw_dependents(targets, prerequisites)
]]

    for _, target in ipairs(targets) do
        local atom_list = ""
        for _, prequisite in ipairs(prerequisites) do
            atom_list = atom_list .. "," .. prerequisite
        end
        code = code:gsub("{target}", target);
        code = code:gsub("{atom_list}", atom_list);
        blud_user_code = blud_user_code .. code
    end

    return targets, prerequisites
end

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

