local M = {}
string_buf = require("string.buffer")



M.deep_copy = function(value, seen)
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local result = {}
    seen[value] = result

    for k, v in pairs(value) do
        result[M.deep_copy(k, seen)] = M.deep_copy(v, seen)
    end

    return result
end

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

-- count_char() count occurrences of char in string
M.count_char = function(text, char)
    return select(2, text:gsub(char, char))
end

M.match_or = function(text, pattern, init)
    assert(type(text) == "string")
    assert(type(pattern) == "string")

    for part in (pattern .. "|"):gmatch("(.-)|") do
        local result = { text:match(part, init) }
        if result[1] ~= nil then
            return unpack(result)
        end
    end
end

-- turn a chunk into a string constant that can later be
-- turned back into a chunk by loadstring()
M.chunk_to_lua = function(chunk)
    local bytecode = string.dump(chunk)
    -- preallocate, add 10 bytes for slop
    local buf = string_buf.new((#bytecode * 4) + 10)
    buf:put("\"")
    for i = 1, #bytecode do
        buf:putf("\\x%02x", bytecode:byte(i))
    end
    buf:put("\"")
    return buf:tostring()
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

-- better version? Delete previous when happy...
M.dump = function(o, seen)
    seen = seen or {}
    local t = type(o)
    if t == 'table' then
        if seen[o] then
            return '"<circular reference>"'
        end
        local s = '{ '
        seen[o] = true

        -- non-numeric keys first
        local numeric = {}
        for k, v in pairs(o) do
            if type(k) == 'number' then
                numeric[#numeric + 1] = k
            else
                s = s .. '["' .. tostring(k) .. '"] = ' .. M.dump(v, seen) .. ', '
            end
        end

        -- numeric keys in ascending order
        table.sort(numeric)
        for _, k in ipairs(numeric) do
            s = s .. '[' .. k .. '] = ' .. M.dump(o[k], seen) .. ', '
        end

        seen[o] = nil
        return s .. '}'
    elseif t == 'string' then
        return string.format("%q", o)
    else
        return tostring(o)
    end
end


M.dump = function(o, seen, path)
    seen = seen or {}
    path = path or "root"
    local t = type(o)
    
    if t == 'table' then
        -- If seen, we can now output exactly WHICH ancestor path it refers to
        if seen[o] then
            return '"<circular reference to ' .. seen[o] .. '>"'
        end
        
        local s = '{ '
        seen[o] = path -- Store the path string instead of true

        -- non-numeric keys first
        local numeric = {}
        for k, v in pairs(o) do
            if type(k) == 'number' then
                numeric[#numeric + 1] = k
            else
                local k_str = tostring(k)
                local next_path = path .. '["' .. k_str .. '"]'
                s = s .. '["' .. k_str .. '"] = ' .. M.dump(v, seen, next_path) .. ', '
            end
        end

        -- numeric keys in ascending order
        table.sort(numeric)
        for _, k in ipairs(numeric) do
            local next_path = path .. '[' .. k .. ']'
            s = s .. '[' .. k .. '] = ' .. M.dump(o[k], seen, next_path) .. ', '
        end

        seen[o] = nil
        return s .. '}'
    elseif t == 'string' then
        return string.format("%q", o)
    else
        return tostring(o)
    end
end

M.print = function(...)
    print(string.format(...))
end
M.printf = function(...)
    io.write(string.format(...))
end

M.string_to_file = function(filename, text)
    assert(filename)
    assert(text)

    local file = assert(io.open(filename, "wb"))
    assert(file:write(text))
    assert(file:close())
end



return M
