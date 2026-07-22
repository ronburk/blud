local M    = {}
-- XXX local sourcemap = require("sourcemap").new()
local m         = require("macro")
local util      = require("util")


--[[



-- tokenize_dependency_line(line)
-- Tokenizes one blud dependency/rule line into an array of token tables.

local function tokenize_line(line)
    local tokens = {}
    local pos    = 1
    local len    = #line
    local c
    local state  = 0

    local function push(type_, text, p)
        assert(type_ and text and p, "token fields must not be nil")
        tokens[#tokens + 1] = { type = type_, text = text, pos = p }
    end

    c = line:sub(pos, pos)
    ::START::
    

    local start, stop, match
    while pos <= len do
        c = line:sub(pos, pos)
        if c:match("%s") then
            start, stop, match = line:find("^([ \t]+)", pos)
            if pos == 1 then push("indent", match, pos) end
            pos = stop
        elseif c:match("^[%a_]+", pos) then
            start, stop, match = line:find("^([%a%d_]+)", pos)
            push("", match, pos)
            pos = stop
        end
        pos = pos + 1
    end
        
        -- skip whitespace
        local ws_start, ws_stop = line:find("^[ \t]+", pos)
        if ws_start then
            pos = ws_stop + 1
        end
        if pos > len then break end

        local c = line:sub(pos, pos)

        if c == ":" then
            -- could be := or plain :
            if line:sub(pos, pos+1) == ":=" then
                push("operator", ":=", pos)
                pos = pos + 2
            else
                push("colon", ":", pos)
                pos = pos + 1
            end

        elseif c == "+" and line:sub(pos, pos+1) == "+=" then
            push("operator", "+=", pos)
            pos = pos + 2

        elseif c == "?" and line:sub(pos, pos+1) == "?=" then
            push("operator", "?=", pos)
            pos = pos + 2

        elseif c == "!" and line:sub(pos, pos+1) == "!=" then
            push("operator", "!=", pos)
            pos = pos + 2

        elseif c == "=" then
            push("operator", "=", pos)
            pos = pos + 1

        else
            -- word: any non-whitespace, non-colon bytes
            local w_start, w_stop = line:find("^[^ \t:+=?!]+", pos)
            if w_start then
                -- check if word is followed immediately by an operator char
                -- that would have been caught above; just grab the plain word
                push("word", line:sub(w_start, w_stop), w_start)
                pos = w_stop + 1
            else
                -- single unrecognized character
                push("error", c, pos)
                pos = pos + 1
            end
        end
    end

    push("eol", "", len + 1)
    return tokens
end

------------------------------------------------------------------------
-- tests
------------------------------------------------------------------------

local tests = {
    "foo : bar baz",
    "foo.o : foo.c foo.h",
    "a b c : x y z",
    "debug : CFLAGS += -g",
    "out := somefile",
    "x ?= default",
    "x != shell_cmd",
    "",
    "   ",
    "single",
}

for _, line in ipairs(tests) do
    print("INPUT: " .. string.format("%q", line))
    local tokens = tokenize_dependency_line(line)
    for _, tok in ipairs(tokens) do
        print(string.format("  [%8s] pos=%-3d %q", tok.type, tok.pos, tok.text))
    end
    print()
end

]]--

--[[
local macro_name_pattern = "([%a_][%w_%.]*)"

-- parse a line that looks like macro assign, or return nil
local match_macro_assign
do
    local operators = {
        ["="]   = true,
        [":="]  = true,
        ["+="]  = true,
        ["?="]  = true,
    }
    function match_macro_assign(line, skip_leading_white)
        -- print("match_macro_assign(\"" .. line .. "\")")
        local anchor = "^"
        if skip_leading_white then anchor = "" end
        local pattern = anchor .. macro_name_pattern .. "%s*([=+:?]+)%s*(.*)$"
        local macro_name, operator, remainder = line:match(pattern)
        if macro_name and operator then
            if operators[operator] == true then
                return { name=macro_name, operator=operator, value=remainder }
            end
        end
        return nil
    end
end
--]]

local TC_WORD = {
    LUASTART = true,
    LUAEND = true,
    LUA_ELSE = true,
    LUA_ELSEIF = true,
    LUA_UNTIL = true,
    WORD = true,
}

local function parts_to_body_lua(parts)
    return util.dump(parts)
--[[
    local result = "{"
    for i, part in ipairs(parts) do
        if i > 1 then
            result = result .. ", "
        end
        if part.type == "text" or part.type == "quote" or part.type == "comment" then
            result = result .. string.format("%q", part.text)
        elseif part.type == "macro" then
            result = result .. "{macro=true"
            for _, arg in ipairs(part) do
                result = result .. ", " .. parts_to_body_lua({ arg })
            end
            result = result .. "}"
        else
            error("unknown macro part type: " .. tostring(part.type))
        end
    end
    return result .. "}"
--]]
end

function compile_macro_assign(compile_io, macro_name)
    local assign_op = compile_io.get_assign_op()

    compile_io.skip_white()
    local macro_text = compile_io.get_line_remainder()
    local parts = m.parts_from_text(macro_text)

    compile_io.emit_line("blud.macro_assign_parts(blud.Scope.bludfile, %q, %q, %s)",
                         macro_name, assign_op, parts_to_body_lua(parts))
end


local function match_colon_operator(text, pos)
    assert(text)
    assert(pos)

    local stop = text:match("^:[%a_][%w_]*:()", pos)
    if stop then
        return stop - 1
    end

    if text:match("^::", pos) then
        return pos + 1
    end

    if text:match("^:%s*", pos) then
        return pos
    end

    return nil
end

local function find_colon_operator_in_text(text)
    local pos = 1

    while true do
        pos = text:find(":", pos, true)
        if not pos then
            return nil
        end

        local stop_pos = match_colon_operator(text, pos)
        if stop_pos then
            return pos, stop_pos
        end

        pos = pos + 1
    end
end

local function append_if_nonempty(parts, part)
    if  part ~= "" then
        table.insert(parts, part)
    end
end

local function split_parts_at_colon_operator(parts)
    local left = {}

    for i, part in ipairs(parts) do
        if type(part) == "string" then
            local op_start, op_stop = find_colon_operator_in_text(part)
            if op_start then
                local right = {}
                local operator = part:sub(op_start, op_stop)
                append_if_nonempty(left, part:sub(1, op_start - 1))
                append_if_nonempty(right, part:sub(op_stop + 1))
                for j = i + 1, #parts do
                    table.insert(right, parts[j])
                end
                return left, operator, right
            end
        end
        table.insert(left, part)
    end
    return nil
end

local function get_line_record(compile_io, after_dependency)
    local text, change, again = compile_io.get_line(after_dependency)
    return {
        text = text,
        change = change,
        again = again,
    }
end


local function action_to_lua(statements)
    if #statements == 0 then
        return "nil"
    end

    return "function(scope, status) " ..
        table.concat(statements, "; ") ..
        " end "
end

local function append_action_line(statements, macro_text)
    local parts = m.parts_from_text(macro_text)
    local command = m.parts_to_lua_expression(parts)

    table.insert(
        statements,
        "status =  blud.execute(scope, " .. command .. ")" ..
        "; if status ~= 0 then return status end"
    )
end

local compile_directives

local function pop_lookahead(compile_io, record)
    assert(record.change == compile_io.POP)
    if record.again then
        return nil
    end
    record.change = nil
    return record
end

local function compile_action(compile_io)
    local record = get_line_record(compile_io, true)

    if record.change ~= compile_io.PUSH then
        return "nil", record
    end

    record.change = nil
    if record.text == nil then
        record = nil
    end

    local statements = {}

    while true do
        if record == nil then
            record = get_line_record(compile_io, false)
        end

        if record.change == compile_io.POP then
            return action_to_lua(statements),
                   pop_lookahead(compile_io, record)
        elseif record.change == compile_io.PUSHCOLON then
            record.change = nil
            record = compile_directives(compile_io, record, true)
        elseif record.change == compile_io.PUSH then
            compile_io.error("Unexpected nested action indentation")
        elseif record.text == "" then
            return action_to_lua(statements), record
        else
            append_action_line(statements, record.text)
            record = nil
        end
    end
end

local function compile_rule_or_target_assignment(compile_io)
    local parts = m.parts_from_text(compile_io.get_current_line())
    local left_parts, operator, right_parts = split_parts_at_colon_operator(parts)

    if not operator then
        compile_io.error("Expected dependency rule")
    end

    assert(compile_io.get_token() == "EOL")
    local action, lookahead = compile_action(compile_io)

    compile_io.emit_line("blud.eval_rule(%q, %s, %s, %s)",
                         operator,
                         parts_to_body_lua(left_parts),
                         parts_to_body_lua(right_parts),
                         action)
    return lookahead
end

local function emit_lua_line(compile_io, line)
    local parts = m.parts_from_text(line)
    compile_io.emit_line("%s", m.parts_to_lua(parts))
end

local function lua_opener(token_text)
    if token_text == "local" then
        return "function"
    end
    return token_text
end

local function update_lua_blocks(compile_io, blocks, token_type, token_text)
    if token_type == "LUASTART" then
        table.insert(blocks, lua_opener(token_text))
    elseif token_type == "LUA_ELSEIF" or token_type == "LUA_ELSE" then
        local block = blocks[#blocks]
        if block ~= "if" and block ~= "elseif" and block ~= "else" then
            compile_io.error("Unexpected Lua %s", token_text)
        end
        blocks[#blocks] = token_text
    elseif token_type == "LUA_UNTIL" then
        if blocks[#blocks] ~= "repeat" then
            compile_io.error("Lua until without matching repeat")
        end
        table.remove(blocks)
    elseif token_type == "LUAEND" then
        if blocks[#blocks] == nil or blocks[#blocks] == "repeat" then
            compile_io.error("Lua end without matching block")
        end
        table.remove(blocks)
    end
end

local function first_lua_token(compile_io)
    local token_type, token_text = compile_io.get_token()
    while token_type == "LEADWHITE" do
        token_type, token_text = compile_io.get_token()
    end
    return token_type, token_text
end

local function compile_lua(compile_io, first_record,
                           first_token_type, first_token_text)
    local blocks = {}
    local record = first_record
    local token_type = first_token_type
    local token_text = first_token_text

    while true do
        if record.change == compile_io.PUSHCOLON then
            record.change = nil
            record = compile_directives(compile_io, record, true)
        elseif record.change == compile_io.POP then
            compile_io.error("Lua block ended before its closing line")
        elseif record.text == "" then
            compile_io.error("Lua block reached EOF before its closing line")
        else
            if token_type == nil then
                token_type, token_text = first_lua_token(compile_io)
            end

            update_lua_blocks(compile_io, blocks, token_type, token_text)
            emit_lua_line(compile_io, compile_io.get_current_line())

            if #blocks == 0 then
                return nil
            end

            record = get_line_record(compile_io, false)
            token_type = nil
            token_text = nil
        end
    end
end

compile_directives = function(compile_io, first_record, nested)
    local record = first_record

    while true do
        if record == nil then
            record = get_line_record(compile_io, false)
        end

        if record.change == compile_io.POP then
            if not nested then
                compile_io.error("Unexpected structural pop")
            end
            return pop_lookahead(compile_io, record)
        elseif record.change == compile_io.PUSHCOLON then
            record.change = nil
            record = compile_directives(compile_io, record, true)
        elseif record.change == compile_io.PUSH then
            compile_io.error("Unexpected action indentation")
        elseif record.text == "" then
            return record
        else
            local token_type, token_text = compile_io.get_token()

            if token_type == "COMMENT" or token_type == "EOL" then
                record = nil
            elseif token_type == "LEADWHITE" then
                compile_io.error("Line looks like action, but is not part of rule")
            elseif TC_WORD[token_type] and compile_io.peek_assign() then
                compile_macro_assign(compile_io, token_text)
                record = nil
            elseif token_type == "LUASTART" then
                record = compile_lua(
                    compile_io,
                    record,
                    token_type,
                    token_text
                )
            else
                record = compile_rule_or_target_assignment(compile_io)
            end
        end
    end
end

function M.compile(compile_io)
    compile_io.emit_line("local scope = blud.Scope.bludfile")
    compile_directives(compile_io, nil, false)
end

return M
