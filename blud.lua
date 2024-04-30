-- blud.lua

-- returns generator that lets you read/peek one line at a time from the file
function buffered_line_io(file)
    local current_line = file:read("*l")  -- Read the first line to prime the generator
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
    print("indent of '" .. line .. "' = " .. indent);
    return indent
end

function preprocess(get_line)
    local previous_indent   = 0
    local makeRulePattern = "^%s*(%S*%s*):.*$"

    while true do
        --    for line in file:lines() do
        local line = get_line(false)
        if line == nil then break end
        if line:match(makeRulePattern) then
            process_make_rule(line)  -- Pass to the processing function if it looks like a 'make' rule.
            local indent = calculate_indent(line)
            while calculate_indent(get_line(true)) > indent do
                print(">>>" .. get_line(false))
            end
        else
            print(line)  -- Output the line as is.
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
    if target_part ~= "" then
        for target in target_part:gmatch("%S+") do
            table.insert(targets, target)
        end
    end

    -- Check and split the prerequisite part into paths
    if prerequisite_part ~= "" then
        for prerequisite in prerequisite_part:gmatch("%S+") do
            table.insert(prerequisites, prerequisite)
        end
    end

    for _, t in ipairs(targets) do
        
    end
    

    -- Debug: Output the results
    print("Targets:")
    for _, t in ipairs(targets) do
        print(t)
    end

    print("Prerequisites:")
    for _, p in ipairs(prerequisites) do
        print(p)
    end
end

-- Call the function to process the file.
local bludfile = "blud"
local file     = io.open(bludfile, "r")  -- Open the file for reading.
if not file then
    print("Failed to open file: " .. filePath)
    return
end
preprocess(buffered_line_io(file))
file:close()


