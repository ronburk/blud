local M = {}
string_buf = require("string.buffer")


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
