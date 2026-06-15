local M = {}

local util = require("util")


local macro_name_pattern = "([%a_][%w_%.]*)"

-- parse a line that looks like macro assign, or return nil
do
    local operators = {
        ["="]   = true,
        ["+="]  = true,
        ["?="]  = true,
    }
    function M.match_macro_assign(line, skip_leading_white)
        print("match_macro_assign(\"" .. util.dump(line) .. "\")")
        local anchor = "^"
        if skip_leading_white then anchor = "" end
        local pattern = anchor .. macro_name_pattern .. "%s*([=+:?]+)%s*(.*)$"
        local macro_name, operator, remainder = line:match(pattern)
        if macro_name and operator then
            if operators[operator] == true then
                return { name=macro_name, operator=operator, macro_text=remainder }
            end
        end
        return nil
    end
end


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
--                  result = { type="comment", text=self.text:sub(start_pos) }
                    result = nil
                    self.pos = self.len + 1
                elseif stop_char == '-' then -- stopped in case it was --, but it wasn't so look further
                    self.pos = stop_pos + 1  -- scan will resume after this '-'
                    goto SCAN
                elseif stop_char == '"' or stop_char == "'" then
                    stop_pos = self:find_lua_short_string_end(stop_char, self.pos)
                    if stop_pos then
                        result = { type="text", text=self.text:sub(self.pos, stop_pos) }
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
        "text:abc "
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
        "text:\"abc\"|text: tail"
    )

    assert_eq(
        "unterminated quote should preserve remaining text",
        collect("abc \"unterminated"),
        "text:abc |text:\"unterminated"
    )
end

--[[
local function append_part(parts, part)
    assert(parts)
    assert(part)

    local previous = parts[#parts]

    if      part.type == "text"
        and previous
        and previous.type == "text"
    then
        previous.text = previous.text .. part.text
    else
        table.insert(parts, part)
    end
    end
--]]

local function append_part(parts, part)
    assert(parts)
    assert(part)

    local previous = parts[#parts]

    if previous ~= nil
        and type(previous) == "string"
        and type(part) == "string"
    then
        parts[#parts] = previous .. part
    else
        table.insert(parts, part)
    end
end

M.parts_from_text = function(text)
    assert(text)
    local scanner = Scanner.new(text)
    local result  = M.parts_from_text_(scanner)
    return result
end


M.parts_from_text_ = function(scanner,     stop_chars)
    stop_chars        = stop_chars or ""
    local result      = {}
    local part        = scanner:get_next_part(stop_chars)
    while part do
        if part.type == "stop" and part.text == "$" then
            local macro_call = M.macro_extract_call(scanner)
            append_part(result, macro_call)
        elseif part.type == "stop" then
            scanner:unget_part(part)
            return result
        else
            assert(part.type == "text")
--            append_part(result, part)
            append_part(result, part.text)
        end
        part = scanner:get_next_part(stop_chars)
    end
    return result
end


-- macro_extract_call:
--     extract macro invocation from scanner. No error return,
-- if it's not looking like a macro, we just skip the '$'
-- returns a symbolic macro reference, including any actual parameters
M.macro_extract_call = function(scanner)
    local arg_stack  = {macro=true, eval="delay"}
    local first_char = scanner:get_char()
    local close_char = ({["("]=")", ["{"]="}"})[first_char]

    if not close_char then    -- if single-char macro with no arguments
        arg_stack[1] = {first_char}
    else    -- else looks like paren-style macro invocation
        if close_char == '}' then arg_stack.eval = "immediate" end
        local parts
        parts = M.parts_from_text_(scanner, " "..close_char)
        if #parts <= 0 then
            error("empty macro invocation")
        else
--            assert(parts[1].type == "text" and parts[1].text ~= "")
--            util.array_append(arg_stack, parts)
            table.insert(arg_stack, parts)
            local macro_name = parts[1]
            local stop_part  = scanner:get_next_part(" "..close_char)
            if stop_part.text == ' ' then
                error("can't handle macro args yet")
            elseif stop_part.text ~= close_char then
                error(string.format("malformed macro call '%s' because of '%s'",
                                    macro_name, stop_part.text))
            else  -- else we hit closing paren of macro call
                
            end
        end
    end
    return arg_stack
end


local function q(s)
    return string.format("%q", s)
end


local function part_to_lua(part)
    assert(type(part) == "table")
    assert(part.type)

    if part.type == "text"
    or part.type == "quote"
    or part.type == "comment"
    or part.type == "stop" then
        assert(type(part.text) == "string")
        return string.format(
            "{ type = %q, text = %q }",
            part.type,
            part.text
        )
    end

    if part.type == "macro" then
        local result = {
--            string.format("{ type = %q,", part.type)
            string.format("{ type = %q, eval = %q,", part.type, part.eval or "delay")
        }

        for i = 1, #part do
            table.insert(result,
                string.format("    [%d] = %s,", i, part_to_lua(part[i]))
            )
        end

        table.insert(result, "}")

        return table.concat(result, "\n")
    end

    error("unknown part type: " .. tostring(part.type))
end

M.parts_to_lua = function(parts)
    assert(type(parts) == "table")
    return util.dump(parts)
--[[
    local result = { "{" }

    for _, part in ipairs(parts) do
        table.insert(result, "    " .. part_to_lua(part) .. ",")
    end

    table.insert(result, "}")

    return table.concat(result, "\n")
--]]
end

M.part_to_lua_function = function(part)
    if type(part) == "string" then
        return string.format("%q", part)
    end
    assert(type(part) == "table")
    
    if part.macro then
        assert(part[1])
        local result = "scope:get_text(" .. M.parts_to_lua_function(part[1])
        return result .. ")"
    else
        assert(false, "unknown part type!")
    end
    
end

M.parts_to_lua_function = function(parts)
    local result = ""
    for _, part in ipairs(parts) do
        if result ~= "" then result = result .. " .. " end
        result = result .. M.part_to_lua_function(part)
    end
    return result
end



---[=[UNIT_TESTS
do
    local function part_to_string(part)
        if type(part) == "string" then
            return "text:" .. string.format("%q", part)
        end

        assert(type(part) == "table")

        if part.macro then
            local args = {}
            for i = 1, #part do
                table.insert(args, parts_to_string(part[i]))
            end

            local open, close = "(", ")"
            if part.eval == "immediate" then
                open, close = "{", "}"
            end

            return "macro" .. open .. table.concat(args, ", ") .. close
        end

        error("unknown part: " .. util.dump(part))
    end

    function parts_to_string(parts)
        local result = {}
        for i = 1, #parts do
            table.insert(result, part_to_string(parts[i]))
        end
        return table.concat(result, " | ")
    end

    local function check_final_format(parts)
        assert(type(parts) == "table")

        for i = 1, #parts do
            local part = parts[i]

            if type(part) == "string" then
                -- OK
            elseif type(part) == "table" and part.macro then
                assert(part.eval == "delay" or part.eval == "immediate")
                for j = 1, #part do
                    check_final_format(part[j])
                end
            else
                error("not final parts format: " .. util.dump(part))
            end
        end
    end

    local function check_parts(text, expected)
        local parts = M.parts_from_text(text)
        check_final_format(parts)

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

    local function check_error(text)
        local ok = pcall(function()
            M.parts_from_text(text)
        end)
        if ok then
            error("parts_from_text(" .. string.format("%q", text) .. ") should have failed", 2)
        end
    end

    check_parts(
        "abc",
        'text:"abc"'
    )

    check_parts(
        "abc$",
        'text:"abc$"'
    )

    check_parts(
        "$x",
        'macro(text:"x")'
    )

    check_parts(
        "$(FOO)",
        'macro(text:"FOO")'
    )

    check_parts(
        "${FOO}",
        'macro{text:"FOO"}'
    )

    check_parts(
        "a$b",
        'text:"a" | macro(text:"b")'
    )

    check_parts(
        "abc$(FOO)def",
        'text:"abc" | macro(text:"FOO") | text:"def"'
    )

    check_parts(
        "abc${FOO}def",
        'text:"abc" | macro{text:"FOO"} | text:"def"'
    )

    check_parts(
        "$($(NAME))",
        'macro(macro(text:"NAME"))'
    )

    check_parts(
        "$(${NAME})",
        'macro(macro{text:"NAME"})'
    )

    check_parts(
        "a-b",
        'text:"a-b"'
    )

    check_parts(
        "a--comment",
        'text:"a"'
    )

    check_parts(
        [["abc" -- comment]],
        'text:"\\"abc\\" "'
    )

    check_parts(
        "'abc'",
        'text:"\'abc\'"'
    )

    check_parts(
        [["a\"b"]],
        'text:"\\"a\\\\\\"b\\""'
    )

    check_parts(
        [["$FOO"]],
        'text:"\\"$FOO\\""'
    )

    check_parts(
        [['$@']],
        'text:"\'$@\'"'
    )

    check_parts(
        "-Wall -Wextra -fmax-errors=2 -I/usr/local/include/luajit-2.1",
        'text:"-Wall -Wextra -fmax-errors=2 -I/usr/local/include/luajit-2.1"'
    )

    check_error("$()")
    check_error("${}")
end
--]=]

return M
