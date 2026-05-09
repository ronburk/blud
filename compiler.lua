local M    = {}
local sourcemap = require("sourcemap")

print("loaded compiler.lua")


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

local translate
do
    function translate(compile_io)
        print("tranlate()")
        local state = "OUTERMOST"
        while state ~= "END" do
            local line = compile_io.get_line()
            if state == "OUTERMOST" then
                if line_is_lua_start then
                    compile_io.emit_line(line)
                    state = "OUTERMOST_LUA"
                else
                    translate_directive(compile_io, line)
                end
            elseif state == "OUTERMOST_LUA" then
            end
            end
        end
    end
end


local translate_make_directives
do
    function translate_make_directives(compile_io)
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
    print("blud.compile()\n")
    local source_ln = 1
    sourcemap.append("<internal>", source_ln, "function blud.bludfile_main()\n")
    source_ln = source_ln + 1
    translate(compile_io)
    sourcemap.append("<internal>", source_ln, "end\n")
    return sourcemap.tostring() .. sourcemap.to_lua()
end

return M
