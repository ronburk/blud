local M    = {}
-- XXX local sourcemap = require("sourcemap").new()
local m         = require("macro")
local util      = require("util")


local function is_blank_or_comment(line)
    assert(type(line) == "string")

    if line:match("^%s*$") then
        return true
    end

    if line:match("^%s*%-%-%[=*%[") then
        error("multi-line comment not allowed here: " .. line)
    end

    if line:match("^%s*%-%-") then
        return true
    end

    return false
end

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

-- leading_keyword() - does line start with a Lua keyword we care about?
do
    local keywords   = {
        ["define"]   = true,  -- blud keyword
        ["do"]       = true,
        ["else"]     = true,
        ["elseif"]   = true,
        ["end"]      = true,  -- blud AND Lua keyword
        ["for"]      = true,
        ["function"] = true,
        ["if"]       = true,
        ["local"]    = true,
        ["repeat"]   = true,
        ["until"]    = true,
        ["while"]    = true,
    }

    function leading_keyword(line)
        local result = nil

        local keyword = line:match("^%a+")
        if keyword == "local" and line:match("local%s+function%s+") then
            keyword = "function"
        end
        if keywords[keyword] then result = keyword end
        return result
    end
end

do
    local leading = {
        ["do"]       = true,
        ["for"]      = true,
        ["function"] = true,
        ["if"]       = true,
        ["local"]    = true,
        ["repeat"]   = true,
        ["while"]    = true
    }
    function is_start_keyword(word)
        return leading[word] == true
    end
end



local macro_name_pattern = "([%a_][%w_%.]*)"

-- parse a line that looks like macro assign, or return nil
local match_macro_assign
do
    local operators = {
        ["="]   = true,
        [":="]  = true,
        ["+="]  = true,
    }
    function match_macro_assign(line)
        --    print("match_macro_assign(\"" .. line .. "\")")
        local pattern = "^" .. macro_name_pattern .. "%s*([=+:]+)%s*(.*)$"
        local macro_name, operator, remainder = line:match(pattern)
        if macro_name and operator then
            if operators[operator] == true then
                return { name=macro_name, operator=operator, value=remainder }
            end
        end
        return nil
    end
end

local translate_make_rule
do
    function translate_make_rule(compile_io, line)
    end
end




local translate_make_directive
do
    local function match_rule_operator(text)
        local start_pos = text:find(":", 1, true)
        if not start_pos then
            return nil
        end

        local stop_pos = text:match("^:[A-Za-z_][A-Za-z0-9_]*:()", start_pos)
        if stop_pos then
            return start_pos, stop_pos - 1
        end

        if text:sub(start_pos, start_pos + 1) == "::" then
            return start_pos, start_pos + 1
        end

        return start_pos, start_pos
    end
    local function parts_from_dependency_line(line)
        local result = nil
        local parts  = m.parts_from_text(line)
        for _, part in ipairs(parts) do
            if part.type == "text" then
                local start_pos, end_pos = match_rule_operator(part.text)
                if not start_pos then break end
            end
        end
        return result
    end

    function translate_make_directive(compile_io, line)
        local macro = match_macro_assign(line)
        if macro then
            compile_io.emit_line("blud.macro_assign(%q,%q,%q)",
            macro.name, macro.operator, macro.value)
        elseif is_blank_or_comment(line) then
            compile_io.emit_line(line)
        else
            local parts = parts_from_dependency_line(line)
            print(util.dump(parts))
            compile_io.error("Don't know what this line is: %s", line)
        end
    end
end

local translate_lua
do
    function translate_lua(compile_io, line)
        local keyword_stack = {}
        local keyword_top   = leading_keyword(line)
        compile_io.emit_line(line)
    end
end


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
end

function compile_macro_assign(compile_io, macro_name)
    local assign_op = compile_io.get_assign_op()

    compile_io.skip_white()
    local macro_text = compile_io.get_line_remainder()
    local parts = m.parts_from_text(macro_text)

    compile_io.emit_line("blud.macro_assign_parts(blud.scope_bludfile, %q, %q, %s)",
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
    if part.type ~= "text" or part.text ~= "" then
        table.insert(parts, part)
    end
end

local function split_parts_at_colon_operator(parts)
    local left = {}

    for i, part in ipairs(parts) do
        if part.type == "comment" then
            break
        end
        if part.type == "text" then
            local op_start, op_stop = find_colon_operator_in_text(part.text)
            if op_start then
                local right = {}
                local operator = part.text:sub(op_start, op_stop)
                append_if_nonempty(left, {
                    type = "text",
                    text = part.text:sub(1, op_start - 1),
                })
                append_if_nonempty(right, {
                    type = "text",
                    text = part.text:sub(op_stop + 1),
                })
                for j = i + 1, #parts do
                    if parts[j].type == "comment" then
                        break
                    end
                    table.insert(right, parts[j])
                end
                return left, operator, right
            end
        end
        table.insert(left, part)
    end
    return nil
end

-- we compile an action into a function that accepts a scope as an
-- argument.
function compile_action(compile_io)
    local action = ""
    if compile_io.is_indented_line() then
        while compile_io.is_indented_line() do
            compile_io.skip_white()
            local macro_text = compile_io.get_line_remainder()
            assert(compile_io.get_token() == "EOL")
            local parts = m.parts_from_text(macro_text)
            if #action > 0 then action = action .. ", " end
            action =  action .. m.parts_to_lua_function(parts) 
            action = "status =  blud.execute(scope, " .. action .. ")" ..
                "; if status ~= 0 then return status end"
        end
        if action ~= "" then
            action = "function(scope, status) " .. action .. " end "
        end
    end
--    action = "function (scope)
    if action == "" then action = "nil" end
    return action
end


-- We don't know what this line is, so we hope it is a dependency rule
--    a b c d :OP: d e f
-- or a target assignment
--    a b c d : name <assign_op> text
-- we are called with the first token on the line, which we know started
-- in column 1.
function compile_rule_or_target_assignment(compile_io, token_type, token_text)
    local parts = m.parts_from_text(compile_io.get_current_line())
    local left, operator, right = split_parts_at_colon_operator(parts)

    if not operator then
        compile_io.error("Expected dependency rule")
    end
    if right and #right > 0 and right[1].type == "text" then
--        print("Should check for target-scoiped macro assign")
    end
    
    -- next step:
    -- decide whether right begins with target-specific macro assignment
    -- otherwise emit blud.add_rule_parts(left, operator, right, action)
    local action = ""
    -- eat end of line, if any
    local token_type, token_text = compile_io.get_token()
    if token_type ~= "EOF" then
        assert(token_type == "EOL")
        action = compile_action(compile_io)
        token_type, token_text = compile_io.get_token()
    end
    compile_io.emit_line("blud.eval_rule(%q, %s, %s, %s)",
                         operator,
                         parts_to_body_lua(left),
                         parts_to_body_lua(right),
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


-- outermost translate loop
local translate
do
    function translate(compile_io)
        while true do
            local line = compile_io.get_line()
            if line == nil then break end
            if is_start_keyword(leading_keyword(line)) then
                translate_lua(compile_io, line)
            else
                translate_make_directive(compile_io, line)
            end
        end
        return nil
    end
end


local translate_bludfile
do
    local start_keywords = {["do"]=true, ["function"]=true, ["if"]=true, ["repeat"]=true}
    function translate_bludfile(compile_io)
        local source_ln     = 0
        local line
        local text          = ""
        local keyword_stack = {}
        local error = function (...)
            syntax_error(line, source_ln, ...)
        end

        while true do
            ::NEXT::
            source_ln   = source_ln + 1
            line        = compile_io.get_line()
            if line == nil then break end -- end of file
            if phase1_line_is_empty(line) then
                compile_io.emit_line(line)
                goto NEXT
            end
            local keyword     = leading_keyword(line)
            local top_keyword = keyword_stack[#keyword_stack]
            if not keyword then -- if not Lua block start/end
                local macro = match_macro_assign(line)
                if top_keyword then   -- copying Lua code ??? handle embedded make code
                    line = phase1_embedded_make(line)
                else -- copying non-Lua code
                    line = "blud.phase2_append(" .. lua_quote(line) .. ")"
                end
            elseif start_keywords[keyword] then
                if top_keyword then error("already inside '#1'", top_keyword) end
                table.insert(keyword_stack,keyword)
            elseif keyword == "end" then
                if not top_keyword then
                    error("Unexpected 'end'")
                else
                    table.remove(keyword_stack)
                end
            elseif keyword == "elseif" or keyword == "else" then
                if top_keyword ~= "if" and top_keyword ~= "elseif" then
                    error("Unexpected '#1' doesn't match open '#2'", keyword, top_keyword)
                else
                    keyword_stack[#keyword_stack] = keyword
                end
            elseif keyword == "local" then
                -- just copy the line
            else
                -- ???
                assert(false)
                line =  "blud.phase2_append(" .. lua_quote(line) .. ")"
            end
            compile_io.emit_line(line)
--            sourcemap.append_line(name, source_ln, line);
            text = text .. line .. "\n"
        end
        return text
    end
end

-- When processing Lua code, it could have text in column 1 due to
-- a string constant or a comment. Here, we check for that possibility
-- and return nil if it's not true, else a string that signifies what the end
-- of the multi-line string/comment should look like
function skip_long_quote_lua(line, pos)
    local match = line:match("=*%[", pos)
    if not match then return nil end -- wasn't start of long quote after all
    local count = #match - 2
    assert(count >= 0);
    local end_quote = "]" .. string.rep("=", count) .. "]"
    pos = line:find(end_quote, pos, true)
    if pos then
        return pos + #end_quote
    else
        return end_quote
    end
end

function find_multiline_start_lua(line, pos)
    pos = line:find("['\"-[]", pos)
    while pos do
        local hit = line:sub(pos, 1)
        if hit == '[' then
            pos = skip_long_quote_lua(line, pos)
        elseif hit == '-' then
            pos = skip_comment_lua(line, pos)
        elseif hit == '"' or hit == "'" then
            pos = skip_short_quote_lua(line, pos, hit)
        else
            assert(false)
        end
        if not pos then break end
        pos = line:find("['\"-[]", pos)
    end
    return pos
end

function find_multiline_lua(line)
    local pos = line:find("['\"-[]")
    while pos do
        local hit = line:sub(pos, 1)
        if hit == '"' then
            --
        elseif hit == "'" then
            --
        elseif hit == '[' then
            --
        end
    end
end

-- function M.compile(name, get_line)
function M.compile(compile_io)
    local source_ln = 1
--XXX    sourcemap:append("<internal>", source_ln, "function blud.bludfile_main()\n")
    source_ln = source_ln + 1
    --    translate(compile_io)
    compile(compile_io)
--XXX    sourcemap:append("<internal>", source_ln, "end\n")
--XXX    return sourcemap:tostring() .. sourcemap:to_lua()
end

return M
