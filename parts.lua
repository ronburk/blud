-- A Parts object is a sequence of literal strings and macro-call tables.
-- This module treats both Parts objects and macro calls as immutable. It does
-- not inspect macro calls; their meaning is supplied by the expansion caller.

local Parts = {}
Parts.__index = Parts


local function is_parts(value)
    return type(value) == "table" and getmetatable(value) == Parts
end


-- Append one part while keeping the representation canonical: empty strings
-- are omitted and adjacent strings are combined.
local function append_part(result, part)
    local part_type = type(part)

    if part_type == "string" then
        if part == "" then
            return
        end

        local previous = result[#result]
        if type(previous) == "string" then
            result[#result] = previous .. part
        else
            table.insert(result, part)
        end
    elseif part_type == "table" and not is_parts(part) then
        table.insert(result, part)
    else
        error("a part must be a string or macro-call table", 3)
    end
end


local function create_from_canonical(elements)
    return setmetatable({ elements = elements }, Parts)
end


-- Copy the supplied array so later changes to the array do not change the
-- Parts object. Macro-call tables are deliberately shared and must be treated
-- as immutable by their owner.
function Parts.create(elements)
    assert(type(elements) == "table")

    local result = {}
    for _, part in ipairs(elements) do
        append_part(result, part)
    end
    return create_from_canonical(result)
end


-- Return a new Parts object containing each Parts or string operand in order.
-- No operand is modified.
function Parts.concat(...)
    local result = {}

    for i = 1, select("#", ...) do
        local operand = select(i, ...)
        if type(operand) == "string" then
            append_part(result, operand)
        elseif is_parts(operand) then
            for _, part in operand:iter() do
                append_part(result, part)
            end
        else
            error("Parts.concat operands must be Parts objects or strings", 2)
        end
    end

    return create_from_canonical(result)
end


function Parts:is_empty()
    return #self.elements == 0
end


-- Return a read-only iterator without exposing the underlying array.
function Parts:iter()
    local index = 0

    return function()
        index = index + 1
        local part = self.elements[index]
        if part ~= nil then
            return index, part
        end
    end
end


-- expand_macro_call is the only operation that may consult outside state.
-- The context is opaque to this module and is merely passed through.
function Parts:expand(context, expand_macro_call)
    assert(type(expand_macro_call) == "function")

    local result = {}
    for _, part in self:iter() do
        if type(part) == "string" then
            table.insert(result, part)
        else
            local expansion = expand_macro_call(context, part)
            if type(expansion) ~= "string" then
                error("macro-call expansion must return a string", 2)
            end
            table.insert(result, expansion)
        end
    end
    return table.concat(result)
end


---[=[UNIT_TESTS
do
    local function assert_equal(actual, expected)
        if actual ~= expected then
            error(
                "expected " .. tostring(expected) ..
                ", got " .. tostring(actual),
                2
            )
        end
    end

    local function assert_fails(fn, expected)
        local ok, message = pcall(fn)
        if ok then
            error("expected failure containing " .. expected, 2)
        end
        if not tostring(message):find(expected, 1, true) then
            error(
                "expected failure containing " .. expected ..
                ", got " .. tostring(message),
                2
            )
        end
    end

    local call = { macro = true, name = "NAME" }
    local elements = { "a", "", "b", call, "c", "d" }
    local parts = Parts.create(elements)

    -- Construction copies and normalizes the outer sequence.
    elements[1] = "changed"
    local seen = {}
    for _, part in parts:iter() do
        table.insert(seen, part)
    end
    assert_equal(#seen, 3)
    assert_equal(seen[1], "ab")
    assert(seen[2] == call)
    assert_equal(seen[3], "cd")
    assert(not parts:is_empty())
    assert(Parts.create({ "" }):is_empty())

    -- Concatenation is functional and also normalizes adjacent strings.
    local suffix = Parts.create({ "d", call })
    local combined = Parts.concat(Parts.create({ "a" }), "bc", suffix)
    local combined_seen = {}
    for _, part in combined:iter() do
        table.insert(combined_seen, part)
    end
    assert_equal(#combined_seen, 2)
    assert_equal(combined_seen[1], "abcd")
    assert(combined_seen[2] == call)

    -- Expansion receives exactly the supplied context and macro call.
    local context = { value = "expanded" }
    local expansion_count = 0
    local expanded = parts:expand(context, function(actual_context, actual_call)
        assert(actual_context == context)
        assert(actual_call == call)
        expansion_count = expansion_count + 1
        return actual_context.value
    end)
    assert_equal(expanded, "abexpandedcd")
    assert_equal(expansion_count, 1)

    assert_fails(
        function()
            Parts.create({ 1 })
        end,
        "a part must be a string or macro-call table"
    )
    assert_fails(
        function()
            Parts.concat(parts, {})
        end,
        "Parts.concat operands must be Parts objects or strings"
    )
    assert_fails(
        function()
            parts:expand(nil, function()
                return false
            end)
        end,
        "macro-call expansion must return a string"
    )
end
--]=]


return Parts
