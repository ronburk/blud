local M = {}

local util = require("util")



--[[

    parts_from_text() - break text into parts
    

]]
-- parts_from_text: break text into parts
--    A macro body is stored as a table. Each entry in the table
-- is either a substring that contains no macro invocations,
-- or else a table that describes a macro call.
local function is_comment(text, pos)
    local result = false
    if text:sub(pos, pos+1) == '--' then
        result = true
    end
    return result
end

-- little scanner class maintains state of a scan
local Scanner   = {}
do
    Scanner.__index = Scanner
    function Scanner.new(text, start_pos)
        local self = {
            text      = text,
            len       = #text,
            start_pos = start_pos or 1,   -- start of what has not been consumed
            pos       = start_pos or 1,   -- pos of char we scan next
            stop_char = nil
        }
        return setmetatable(self, Scanner)
    end
    -- advance to next "stop char"
    function Scanner:advance(pattern)
        local result = false
        if self.pos < len then
            self.pos,_,self.stop_char = text:find(pattern, pos)

            -- if no more stop_chars to find
            -- (also treat $ at end of text as literal)
            if not self.pos or (self.stop_char == '$' and self.stop_pos == len) then
                self.stop_char = nil
                self.pos       = self.len+1
--                table.insert(result, text:sub(pos))
            end
        end
        return false
    end
    function Scanner:consume()
        local result = text:sub(self.start_pos, self.pos)
        self.start_pos = self.pos+1
        self.pos       = self.start_pos
        return result
    end
    function Scanner:stop_char() return self:stop_char end
end

while scanner:advance() do
    local stop_char = scanner:stop_char()
    if stop_char == nil then
        table.insert(result, scanner.consume())
    elseif stop_char == '-' then
        if scanner:is_comment() then
            error("not yet")
        end
    elseif
    end

end


M.parts_from_text = function(text,     stop_chars, scanner, self_reference)
    assert(text)
    stop_chars        = stop_chars or ""
    scanner           = scanner or Scanner.new(text)
    local pattern     = '([%-%$\'\"' .. stop_chars .. '])'
    local result      = {}
    local stop_char
    -- stop_pos is position of last char we have processed
    while scanner:advance(pattern) do
        local stop_char = scanner:stop_char()

        -- if no more stop_chars to find
        -- (also treat $ at end of text as literal)
        if not stop_pos or (stop_char == '$' and stop_pos == len) then
            table.insert(result, text:sub(pos))
            break
        elseif stop_char == '-' then -- might be a comment
            if is_comment(text, stop_pos) then
                error("Don't handle comments yet")
            end
        elseif stop_char == "'" or stop_char == '"' then
            error("Don't handle quotes yet")
        -- else if it is a macro invocation
        elseif stop_char == '$' then
            -- add any text up to the macro invocation
            if stop_pos > pos then
                table.insert(result, text:sub(pos, stop_pos - 1))
            end
            local macro_call, new_pos = blud.macro_extract_call(text, stop_pos, self_reference)
            table.insert(result, macro_call)
--            util.array_append(result, macro_call)
            pos = new_pos
        -- else it's a char that stops our scan (space, comma, right paren)
        else
            if stop_pos > pos then
                table.insert(result, text:sub(pos, stop_pos - 1))
                pos = stop_pos
            end
            break
        end
    end

    return result, pos
end


-- Unit tests
-- Unit tests
if true then
    local function check(condition, message)
        if not condition then
            error("unit test failed: " .. message, 2)
        end
    end

    local function check_stop_char_case(text, stop_chars, expected_part, expected_pos)
        local parts, pos = M.parts_from_text(text, stop_chars)

        check(#parts == 1,
            string.format("parts_from_text(%q, %q): expected 1 part, got %d",
                text, stop_chars, #parts))

        check(parts[1] == expected_part,
            string.format("parts_from_text(%q, %q): expected part[1] = %q, got %q",
                text, stop_chars, expected_part, tostring(parts[1])))

        check(pos == expected_pos,
            string.format("parts_from_text(%q, %q): expected pos = %d, got %s",
                text, stop_chars, expected_pos, tostring(pos)))
    end

    do  -- look for off-by one; text immediately before a stop char must not be dropped
        check_stop_char_case("x)",  ")", "x",  2)
        check_stop_char_case("xy)", ")", "xy", 3)
        check_stop_char_case("a-b)", ")", "a-b", 4)
    end
end


return M
