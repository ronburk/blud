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

local TC_EMPTY = { LEADWHITE=true, COMMENT=true }
local TC_END   = { EOF=true, EOL=true }
local TC_WORD  = { LUASTART=true, LUAEND=true, WORD=true }

function compile_empty_line(compile_io, token_type, token_text)
    while TC_EMPTY[token_type] do
        token_type, token_text = compile_io.get_token()
    end
    if not TC_END[token_type] then
        compile_io.error("Unexpected token: %s", token_text)
    end
    return token_type
end

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

-- Compile the indented action block following a rule.  The result is Lua
-- source for a function that will expand and execute the action later, when
-- the target's scope and automatic variables are available.
function compile_action(compile_io)
    if not compile_io.is_indented_line() then
        return "nil"
    end

    local statements = {}

    local function append_action_line(macro_text)
        local parts = m.parts_from_text(macro_text)
        local command = m.parts_to_lua_expression(parts)

        table.insert(
            statements,
            "status =  blud.execute(scope, " .. command .. ")" ..
            "; if status ~= 0 then return status end"
        )
    end

    -- The first action line establishes the prefix stripped from every
    -- subsequent physical line in this action block.
    local token_type, token_text = compile_io.get_token()
    assert(token_type == "LEADWHITE")
    compile_io.push_strip_prefix(token_text)

    token_type, token_text = compile_io.get_token()
    while token_type ~= "STRIP_END" do
        if token_type == "EOF" then
            error("Action strip prefix reached EOF without STRIP_END")
        elseif token_type ~= "EOL" then
            local macro_text = token_text .. compile_io.get_line_remainder()
            append_action_line(macro_text)
            assert(compile_io.get_token() == "EOL")
        end

        token_type, token_text = compile_io.get_token()
    end

    if #statements == 0 then
        return "nil"
    end

    return "function(scope, status) " ..
        table.concat(statements, "; ") ..
        " end "
end


-- We don't know what this line is, so we hope it is a dependency rule
--    a b c d :OP: d e f
-- or a target assignment
--    a b c d : name <assign_op> text
-- we are called with the first token on the line, which we know started
-- in column 1.
function compile_rule_or_target_assignment(compile_io, token_type, token_text)
    local parts = m.parts_from_text(compile_io.get_current_line())
    local left_parts, operator, right_parts = split_parts_at_colon_operator(parts)

    if not operator then
        compile_io.error("Expected dependency rule")
    end
    -- next step:
    -- decide whether right begins with target-specific macro assignment
--[[
    if right_parts and #right_parts > 0 and right_parts[1].type == "text" then
        print("Should check for target-scoiped macro assign")
        local macro = match_macro_assign(right_parts[1].text, true)
        if macro then
            util.print("Found target-scoped assign: %s", util.dump(macro))
            -- ok, got to turn lhs into an array of target atoms
            local left  = blud.Macro.expand_tokens(blud.scope_bludfile, left_parts)
            local target_names = tokenize_dependency_line(left)

            for i = 1, #target_names do
                compile_io.emit_line(
                    "blud.macro_assign_parts(%q, %q, %q, %s)",
                    target_names[i], macro_name, assign_op, parts_to_body_lua(parts))
            end
            error("x")
        end
    end
--]]
    
    -- otherwise emit blud.add_rule_parts(left, operator, right, action)
    local action = ""
    -- eat end of line, if any
    local token_type, token_text = compile_io.get_token()
    if token_type ~= "EOF" then
        assert(token_type == "EOL")
        action = compile_action(compile_io)
    end
    compile_io.emit_line("blud.eval_rule(%q, %s, %s, %s)",
                         operator,
                         parts_to_body_lua(left_parts),
                         parts_to_body_lua(right_parts),
                         action or "nil")
end


function compile(compile_io)
    local token_type, token_text = compile_io.get_token()

    while token_type ~= "EOF" do
        if TC_EMPTY[token_type] then -- if could be empty line
            compile_empty_line(compile_io, token_type, token_text)
        elseif TC_WORD[token_type] and compile_io.peek_assign() then
            compile_macro_assign(compile_io, token_text)
        elseif token_type == "LEADWHITE" then
            compile_io.error("Line looks like action, but is not part of rule")
        elseif token_type == "LUASTART" then
            compile_lua(compile_io, token_text)
        elseif token_type == "EOL" then
        else
            compile_rule_or_target_assignment(compile_io, token_type, token_text)
        end
        token_type, token_text = compile_io.get_token()
    end
end


function M.compile(compile_io)
    compile(compile_io)
end

return M
