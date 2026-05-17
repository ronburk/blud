local M = {}

local util = require("util")



--[[

    parts_from_text() - break text into parts
    

]]
-- parts_from_text: break text into parts
-- Each part is a table with a "type" field. Each non-macro part has a "text" field.
-- A part with "type" equal to "macro" is an "argstack" array.
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
            pos       = start_pos or 1,
            part      = nil
        }
        return setmetatable(self, Scanner)
    end
    function Scanner:unget_part(part)
        assert(self.part == nil)
        self.part = part
    end
    function Scanner:get_char()
        assert(self.pos <= self.len)

        local ch = self.text:sub(self.pos, self.pos)
        self.pos = self.pos + 1
        return ch
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
        local result   = self.part
        if result then
            self.part = nil
            return result
        end
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

M.parts_from_text = function(text)
    assert(text)
    local scanner = Scanner.new(text)
    return M.parts_from_text_(scanner)
end


M.parts_from_text_ = function(scanner,     stop_chars, self_reference)
    stop_chars        = stop_chars or ""
    local result      = {}
    local part        = scanner:get_next_part(stop_chars)
    while part do
        if part.type == "stop" and part.text == "$" then
            local macro_call = M.macro_extract_call(scanner, self_reference)
            table.insert(result, macro_call)
        elseif part.type == "stop" then
            return result
        else
            table.insert(result, part)

        end
        part = scanner:get_next_part(stop_chars)
    end
    return result
end


-- macro_extract_call:
--     extract macro invocation from scanner. No error return,
-- if it's not looking like a macro, we just skip the '$'
-- returns a symbolic macro reference, including any actual parameters
M.macro_extract_call = function(scanner, self_reference)
    local arg_stack  = {type="macro"}
    local first_char = scanner:get_char()

    if first_char ~= '(' then    -- if single-char macro with no arguments
        table.insert(arg_stack, {type="text", text=first_char})
    else    -- else looks like paren-style macro invocation
        local arg
        arg = M.parts_from_text_(scanner, "[ )]", self_reference)
        if not next(arg) then
            error("empty macro invocation")
        end
        local stop_char = text:sub(pos,pos)
        table.insert(arg_stack, arg)
        if stop_char == ' ' then
            error("can't handle macro args yet")
        elseif stop_char ~= ')' then
            error("malformed macro call: " .. text)
        else  -- else we hit closing paren of macro call
            pos = pos + 1   -- skip over ')'
        end
    end
    if self_reference then
        arg_stack = self_reference(arg_stack)
    end
    return arg_stack
end


-- Unit tests
do
    local function part_to_string(part)
        if part.type == "text" then
            return "text:" .. string.format("%q", part.text)
        elseif part.type == "quote" then
            return "quote:" .. string.format("%q", part.text)
        elseif part.type == "comment" then
            return "comment:" .. string.format("%q", part.text)
        elseif part.type == "stop" then
            return "stop:" .. string.format("%q", part.text)
        elseif part.type == "macro" then
            local args = {}
            for i = 1, #part do
                table.insert(args, parts_to_string(part[i]))
            end
            return "macro(" .. table.concat(args, ", ") .. ")"
        else
            return "unknown:" .. tostring(part.type)
        end
    end

    function parts_to_string(parts)
        local result = {}
        for i = 1, #parts do
            table.insert(result, part_to_string(parts[i]))
        end
        return table.concat(result, " | ")
    end

    local function check_parts(text, expected)
        local parts = M.parts_from_text(text)
        local actual = parts_to_string(parts)

        if actual ~= expected then
            error(
                "parts_from_text(" .. string.format("%q", text) .. ") failed\n" ..
                "expected: " .. expected .. "\n" ..
                "actual:   " .. actual,
                2
            )
        end
    end

    check_parts(
    "abc",
    'text:"abc"'
)

check_parts(
    "abc$(FOO)def",
    'text:"abc" | macro(text:"FOO") | text:"def"'
)

check_parts(
    [["abc" -- comment]],
    'quote:"\\"abc\\"" | text:" " | comment:"-- comment"'
)
end



return M
