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
            pos       = start_pos or 1
        }
        return setmetatable(self, Scanner)
    end
    function Scanner:find_lua_short_string_end(quote, pos)
        pos = pos + 1
        while pos <= self.len do
            local ch = self.text:sub(pos, pos)

            if ch == "\\" then
                pos = pos + 2
            elseif ch == quote then
                return pos
            else
                pos = pos + 1
            end
        end

        return nil
    end
    -- advance to next "stop char"
    function Scanner:get_next_part(stop_chars)
        local result   = nil
        local stop_pos, stop_char
        local pattern  = '([%-%$\'\"' .. stop_chars .. '])'
        local start_pos = self.pos

        if start_pos <= self.len then -- if there are chars left to scan
            ::SCAN::
            stop_pos,_,stop_char = self.text:find(pattern, self.pos)
            if not stop_pos then -- if remainder of string has no special chars
                result   = { type="text", text=self.text:sub(start_pos) }
                self.pos = self.len + 1
            elseif stop_pos > self.pos then -- if there was literal text before the stop char
                result   = { type="text", text=self.text:sub(start_pos, stop_pos-1) }
                self.pos = stop_pos         -- git you next time, sucka!
            else  -- ok, we have a special char of some kind
                -- some are not special if they are last char in string
                if stop_pos == self.len and stop_char:find("['\"$-]") then
                    result   = { type="text", text=self.text:sub(start_pos) }
                    self.pos = self.len + 1
                elseif self.text:sub(stop_pos, stop_pos+1) == '--' then -- if comment
                    result = { type="comment", text=self.text:sub(start_pos) }
                    self.pos = self.len + 1
                elseif stop_char == '-' then -- stopped in case it was --, but it wasn't so look further
                    self.pos = stop_pos + 1  -- scan will resume after this '-'
                    goto SCAN
                elseif stop_char == '"' or stop_char == "'" then
                    stop_pos = self:find_lua_short_string_end(stop_char, self.pos)
                    if stop_pos then
                        result = { type="quote", text=self.text:sub(self.pos, stop_pos) }
                        self.pos = stop_pos + 1
                    else
                        result   = { type="text", text=self.text:sub(self.pos) }
                        self.pos = self.len + 1
                    end
                else
                    result = { type="stop", text=stop_char }
                    self.pos = stop_pos + 1
                end
            end
        end
        return result
    end
end


do
    local function collect(text, stop_chars)
        local s = Scanner.new(text)
        local result = {}

        while true do
            local part = s:get_next_part(stop_chars or "")
            if not part then break end
            table.insert(result, part.type .. ":" .. part.text)
        end

        return table.concat(result, "|")
    end

    local function assert_eq(name, actual, expected)
        if actual ~= expected then
            error(
                name .. " failed\n" ..
                "expected: " .. expected .. "\n" ..
                "actual:   " .. actual,
                2
            )
        end
    end

    assert_eq(
        "comment after text should return text first, then comment",
        collect("abc -- comment"),
        "text:abc |comment:-- comment"
    )

    assert_eq(
        "single '-' is ordinary text, even if returned in adjacent text parts",
        collect("a-b$c", "%$"),
        "text:a|text:-b|stop:$|text:c"
    )
    assert_eq(
        "adjacent stop chars should produce two stop tokens",
        collect("a$$b", "%$"),
        "text:a|stop:$|stop:$|text:b"
    )

    assert_eq(
        "quoted Lua short string should be one quote token",
        collect("\"abc\" tail"),
        "quote:\"abc\"|text: tail"
    )

    assert_eq(
        "unterminated quote should preserve remaining text",
        collect("abc \"unterminated"),
        "text:abc |text:\"unterminated"
    )
end


M.parts_from_text = function(text,     stop_chars, scanner, self_reference)
    assert(text)
    stop_chars        = stop_chars or ""
    scanner           = scanner or Scanner.new(text)
    local pattern     = '([%-%$\'\"' .. stop_chars .. '])'
    local result      = {}
    local stop_char
    -- stop_pos is position of last char we have processed
    while not scanner:empty() do
        local part    = scanner:advance(pattern)
        if part == "$" then
            local macro_call = blud.macro_extract_call(text, scanner, self_reference)
            table.insert(result, macro_call)
        else
            table.insert(result, part)

        end
    end
end
--[[
        if stop_char == '-' then -- might be comment
            
        end
        
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

--]]

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
