local M    = {}
local sourcemap = require("sourcemap")
local m         = require("macro")
local util      = require("util")

print("loaded compiler.lua")

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
    function translate_make_directive(compile_io, line)
        print("translate_make_directive: " .. tostring(line))
        local macro = match_macro_assign(line)
        if macro then
            compile_io.emit_line("blud.macro_assign(%q,%q,%q)",
            macro.name, macro.operator, macro.value)
        elseif is_blank_or_comment(line) then
            compile_io.emit_line(line)
        else
            local foo = m.parts_from_text(line)
            print(util.dump(foo))
            compile_io.error("Don't know what this line is: %s", line)
        end
    end
end

local translate_lua
do
    function translate_lua(compile_io, line)
        print("translate_lua: " .. tostring(line))
        local keyword_stack = {}
        local keyword_top   = leading_keyword(line)
        compile_io.emit_line(line)
    end
end


-- outermost translate loop
local translate
do
    function translate(compile_io)
        print("translate()")
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
                print("parse blud directive: " .. line .. " top=" .. tostring(top_keyword))
                local macro = match_macro_assign(line)
                if top_keyword then   -- copying Lua code ??? handle embedded make code
                    line = phase1_embedded_make(line)
                    print(">>>>", line)
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
    print("blud.compile()")
    local source_ln = 1
    sourcemap.append("<internal>", source_ln, "function blud.bludfile_main()\n")
    source_ln = source_ln + 1
    translate(compile_io)
    sourcemap.append("<internal>", source_ln, "end\n")
    return sourcemap.tostring() .. sourcemap.to_lua()
end

return M
