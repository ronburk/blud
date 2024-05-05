-- blud.lua

top_env = {}
blud_module_code = [[
blud = {}
blud.TARGETS = {}
blud.add_raw_dependents = function(targets, string_list)
    for _, target_name in ipairs(targets) do
        local target = blud.TARGETS[target_name]
        if(target == nil)
            blud.TARGETS[target_name] = target = {}
        local raw_dependents = target.RAW_DEPENDENTS or {}
        for _, dep in ipairs(string_list) do
            table.insert(raw_dependents, dep)
        end
        target.RAW_DEPENDENTS = raw_dependents
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

-- Example function to simulate processing 'make' rules.

function process_make_rule(line)
    -- Initialize arrays
    local targets = {}
    local prerequisites = {}

    -- Split the line at the colon
    local target_part, prerequisite_part = line:match("^%s*(.-)%s*:%s*(.*)")

    -- Check and split the target part into paths
    blud_user_code = blud_user_code .. "    local targets = { "
    for target in target_part:gmatch("%S+") do
        top_env.PRIMARY_TARGET = top_env.PRIMARY_TARGET or target
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

--[[ Call the function to process the file.
local bludfile = "blud"
local file     = io.open(bludfile, "r")  -- Open the file for reading.
if not file then
    print("Failed to open file: " .. filePath)
    return
end
]]
file = io.stdin
preprocess(buffered_line_io(file))
file:close()

function build(target)
    print("build " .. target)
end
x = "x" y = "y"

if top_env.PRIMARY_TARGET == nil then
    print("No target given to build")
else
    build(top_env.PRIMARY_TARGET)
end

print("-----------------------")
print(blud_module_code)
print(blud_user_code);

