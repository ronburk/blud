local M = {}



-- array_append: append one array to another
M.array_append    = function(array, more)
    if not (type(array) == "table" and type(more) == "table") then
        error(string.format("Bad call to array_append(%s, %s)",
                            type(array), type(more)))
    end
    for _, element in ipairs(more) do
        table.insert(array, element)
    end
end

-- dump: simple Lua dumper
M.dump = function(o, seen)
    seen    = seen or {}  -- Initialize the seen table if it's not passed in
    local t = type(o)
    if type(o) == 'table' then
        if seen[o] then  -- Check if this table has already been processed
            return '"<circular reference>"'
        end
        seen[o] = true  -- Mark this table as processed
        local s = '{ '
        for k,v in pairs(o) do
            if type(k) ~= 'number' then k = '"'..k..'"' end
            s = s .. '['..k..'] = ' .. M.dump(v, seen) .. ','
        end
        seen[o] = nil  -- Allow this table to be processed again in other contexts
        return s .. '} '
    elseif t == 'string' then
        return string.format("%q", o)
    else
        return tostring(o)
    end
end


return M
