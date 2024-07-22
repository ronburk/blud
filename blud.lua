blud_module_code = [==[
setmetatable(_G, {
    __index = function(_, key)
        error("Attempt to access undefined global variable: " .. tostring(key), 2)
    end
})

local function dump(o, seen)
    seen = seen or {}  -- Initialize the seen table if it's not passed in
    if type(o) == 'table' then
        if seen[o] then  -- Check if this table has already been processed
            return '"<circular reference>"'
        end
        seen[o] = true  -- Mark this table as processed
        local s = '{ '
        for k,v in pairs(o) do
            if type(k) ~= 'number' then k = '"'..k..'"' end
            if v ~= "__index" then
                s = s .. '['..k..'] = ' .. dump(v, seen) .. ','
            end
        end
        seen[o] = nil  -- Allow this table to be processed again in other contexts
        return s .. '} '
    else
        return tostring(o)
    end
end


local function dump_old(o)
    if type(o) == 'table' then
        local s = '{ '
        for k,v in pairs(o) do
            if type(k) ~= 'number' then k = '"'..k..'"' end
            if v ~= "__index" then
            s = s .. '['..k..'] = ' .. dump(v) .. ','
            end
        end
        return s .. '} '
    else
        return tostring(o)
    end
end

function errorf(format_string, ...)
    if format_string then
        local args = {...}
        local message = format_string:gsub("#(%d+)", function(n)
                                               return tostring(args[tonumber(n)])
        end)
        io.stderr:write(message)
    end
    io.stderr:write("\n")
    os.exit(1)
end

blud                 = {}
blud.operators       = {}
blud.build_name      = nil
blud.primary_targets = nil
--blud.macros          = {}
-- macro scopes
blud.Scope = {}
blud.Scope.__index = blud.Scope
function blud.Scope:new(parent)
    local instance = {
        variables = {},
        parent = parent or nil
    }
    setmetatable(instance, blud.Scope)
    return instance
end
function blud.Scope:set(name, value)
    self.variables[name] = value
end
function blud.Scope:get(name)
    if self.variables[name] ~= nil then
        return self.variables[name]
    elseif self.parent then
        return self.parent:get(name)
    else
        return nil
    end
end
-- per-target scope
-- This handles automatic macros in its "get" function
blud.ScopeTarget         = setmetatable({}, {__index = blud.Scope})
blud.ScopeTarget.__index = blud.ScopeTarget
function blud.ScopeTarget:new(target)
    local scope  = blud.Scope:new(blud.scope_commandline)
    scope.target = target
    setmetatable(scope, blud.ScopeTarget)
    return scope
end
function blud.ScopeTarget:get(name)
print("ScopeTarget:get(", name, ")")
    if name == "<" then
        local first_prereq = self.target.PREREQUISITES[1]
        if first_prereq then
            return blud.macro_tokens_from_string(name, first_prereq.NAME)
        end
--        print(dump(self.target.PREREQUISITES))

    else
        local result = self.variables[name]
        if result == nil and self.parent then
            result = self.parent:get(name)
        end
        return result
    end
end

blud.scope_base        = blud.Scope:new()
blud.scope_environment = blud.Scope:new(blud.scope_base)
blud.scope_bludfile    = blud.Scope:new(blud.scope_environment)
blud.scope_commandline = blud.Scope:new(blud.scope_bludfile)


blud.macro_simple_name_match = function(token, name)
print("simple name match ", name, dump(token))
    if token and type(token) == "table" and token.macro == true then
        -- it's a macro call stack, and [1] will be the tokens making up the name
        local name_tokens = token[1]
        -- we detect FOO = $(FOO) + 1, not FOO = $(F$(OO)) + 1
        if #name_tokens == 1 then
            return name_tokens[1][1] == name
        end
    end
print("NO MATCH on ", name, dump(token))
    return false
end

-- macro_extract_call:
--     extract macro invocation from text at pos. No error return,
-- if it's not looking like a macro, we just skip the '$'
-- returns a symbolic macro reference, including any actual parameters
blud.macro_extract_call = function(text, pos)
print("macro_extract_call: ", text, pos)
    local arg_stack = {macro=true}
    local len       = #text
    assert(pos < len)
    assert(text:sub(pos, pos) == "$")
    pos = pos + 1
    if pos > len then
        error("$ at end of line: " .. text)
    end
    local first_char = text:sub(pos,pos)

    if first_char ~= '(' then    -- if single-char macro with no arguments
        table.insert(arg_stack, {first_char})
    else    -- else looks like full-syntax macro invocation
        local arg
        arg, pos = blud.macro_tokens_from_text(text, "[ )]", pos+1)
        assert(next(arg))
        assert(pos <= len)
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
print(" extract returns ", dump(arg_stack), pos)
    return arg_stack, pos
end

blud.macro_tokens_from_string = function(name, str)
    return {name=name, [1] = str}
end

-- macro_tokens_from_text: compile a macro body into a table
--    A macro body is stored as a table. Each entry in the table
-- is either a substring that contains no macro invocations,
-- or else a table that describes a macro call.
blud.macro_tokens_from_text = function(text, stop_chars, pos)
print("macro_tokens_from_text: ", text, stop_chars, pos)
    stop_chars        = stop_chars or "%$"
    stop_chars        = "(" .. stop_chars .. ")"
    pos               = pos or 1
    local result      = {}
    local len         = #text
print("    >macro_tokens_from_text: ", text, stop_chars, pos)

    while pos <= len do
        local stop_pos,_,stop_char = text:find(stop_chars, pos)
print("    >", pos, stop_pos, stop_char)        
        -- if no more stop_chars to find
        -- (also treat $ at end of text as literal)
        if not stop_pos or (stop_char == '$' and stop_pos == len) then
            table.insert(result, text:sub(pos))
            break
        -- else if it is a macro invocation
        elseif stop_char == '$' then
            -- add any text up to the macro invocation
            if stop_pos > pos then
                table.insert(result, text:sub(pos, stop_pos - 1))
            end
            local macro_call, new_pos = blud.macro_extract_call(text, stop_pos)
            table.insert(result, macro_call)
            pos = new_pos
        -- else it's a char that stops our scan (space, comma, right paren)
        else
            if stop_pos > pos+1 then
                table.insert(result, text:sub(pos, stop_pos - 1))
                pos = stop_pos
            end
            break
        end
    end

print(" tokens_from returns ", dump(result), pos)
    return result, pos
end

blud.match_macro_assign = function(line)
    local operators = {
        ["="]   = true,
        [":="]  = true,
        ["+="]  = true,
    }
    local pattern = "^(%a+)%s*([=+:]+)%s*(.*)$"
    macro_name, operator, remainder = line:match(pattern)
    if macro_name and operator then
        if operators[operator] == true then
            return macro_name, operator, remainder
        end
    end
    return nil
end

blud.build_init = function()
    local OWD = {[1] = ".", ["name"] = "OWD"}
    blud.scope_base:set("OWD", OWD)
--    if blud.build_name then
    if blud.BUILD_DEFAULT then
--        os.execute("mkdir " .. blud.BUILD_DEFAULT.NAME)
print("simulate mkdir " .. blud.BUILD_DEFAULT.NAME)
        OWD = { [1] = blud.BUILD_DEFAULT.NAME, ["name"] = "OWD" }
        blud.scope_bludfile:set("OWD", OWD)
    end
end

blud.lines  = function (str)
    local pos = 1
    return function()
        if pos > #str then return nil end
        local start, stop, line = str:find("([^\r\n]*)[\r\n]?", pos)
        pos = stop + 1
        return line
    end
end

blud.get_macro_args = function (text, pos)
    
end

blud.get_macro_call = function (text, pos)
    local macro = nil
    local char = text:sub(pos, 1)
    if char == '(' then
        local pos, args = blud.get_macro_args(text, pos)
        macro = { name=args[0], args = args }
    else
        macro = { name=char, args = {} }
    end
    return pos, macro
end

-- ??? elaborate to handle context
blud.macro_from_name = function(name, target)
    assert(name ~= nil)
--    local scope = 
    if target ~= nil then
    end
    return blud.macros[name]
end

blud.macro_expand = function(scope, macro_call)
    assert(macro_call ~= nil)

    local result = ""
    local macro = scope:get(macro_call.name)
    if macro then
        assert(macro["name"] ~= nil)
        for _, element in ipairs(macro) do
            if type(element) == "string" then
                result = result .. element
            elseif type(element) == "table" then
    assert(element["name"] ~= nil)
                result = result .. blud.macro_expand(scope, element.name)
            else
                error("Invalid element type in macro: " .. type(element))
            end
        end
    end
    
    return result
end

-- macro_expand_from_text: given text and the offset of a '$', recursively expand
-- just that macro. Return the expansion text and the position just after
-- the macro invocation, where the caller can resume scanning.
-- note the mutual recursion between blud.macro_expand and blud.macro_expand_text
blud.macro_expand_from_text = function (scope, text, pos)
    assert(scope ~= nil)
    local result = ""
    local max_pos= #text
    assert(pos <= max_pos)
    assert(text:sub(pos, pos) == "$")
    pos = pos + 1
    if pos >= max_pos then
        error("Unexpected '$' at end of line.")
    end
    local macro_call
    macro_call, pos = blud.macro_extract_call(text, pos-1)
    result = blud.macro_expand(scope, macro_call)
    return result, pos
end

-- macro_expand_text: return a copy of the supplied text, with
-- each macro invocation recursively expanded.
function blud.macro_expand_text(scope, text, stack)
    local result = {}
    local pos    = 1
    local len    = #text
    stack = stack or {}

    while pos <= len do
        local dollar_pos = string.find(text, "%$", pos)

        if dollar_pos then -- if we found another macro invocation
            -- first append text up to macro invocation
            table.insert(result, string.sub(text, pos, dollar_pos - 1)) 
            local new_text, newPos = blud.macro_expand_from_text(scope, text, dollar_pos, stack)
            table.insert(result, new_text)
            pos = newPos
        else
            -- No more "$" found, accumulate the remaining text
            table.insert(result, string.sub(text, pos, len))
            break
        end
    end

    return table.concat(result)
end

-- macro_assign: assign a body to a macro
-- the value of a macro will always be a function which returns either
-- a string, or the macro-expanded value of a string.
blud.macro_assign = function(line, scope, macro)
print("macro_assign: ", line, macro.name, macro.operator, macro.body_pos)
    local macro_tokens = blud.macro_tokens_from_text(line, nil, macro.body_pos);
    local result   = line
    local operator = macro.operator
    if operator == "=" then
        local temp = {}
        for _, element in ipairs(macro_tokens) do
print("name: ", macro.name, "for: ", _, dump(element) )
            if blud.macro_simple_name_match(element, macro.name) then
print("    MATCH!")
                local referenced_macro = scope:get(macro.name)
                for __, other in ipairs(referenced_macro) do
                    table.insert(temp, other)
                end
            else
                table.insert(temp, element)
            end
        end
        -- copy over non-array elements
        for k, v in pairs(macro_tokens) do
            if type(k) ~= "number" then
                temp[k] = v
            end
        end

        macro_tokens = temp
    elseif operator == ":=" then
        macro_tokens = {blud.macro_expand_text(scope, input)}
    else
        error("Unknown assignment operator '" .. macro.operator .. "':" .. line)
        assert(false)
    end
--    if blud.macros[macro_name] then
--        print("replacing table ", blud.macros[macro_name], " = ", dump(blud.macros[macro_name]))
--    end
print("scope: ", dump(scope))
    scope:set(macro.name, macro_tokens)
print("macro assign ", macro.name, " table ", macro_tokens, " with value ", dump(macro_tokens))
    return result
end



blud.phase2_text  = ""
blud.phase2_append= function(str)
    blud.phase2_text = blud.phase2_text .. str .. "\n"
end
blud.phase3_text  = ""
blud.phase3_append= function(str)
    if str == nil then str = "" end
    blud.phase3_text = blud.phase3_text .. str .. "\n"
end

blud.string_stack = function(str, pos)
    return {
        { str, pos },
        push = function(str, pos)
            table.insert(this, {str=str,pos=pos})
        end,
        pop = function()
            table.remove(this)
            return #this
        end,
        get_char = function(expanding)
            while #this do
                local finger = this[#this]
                if finger.pos >= #finger.str then
                    table.remove(this)
                else
                    while true do
                        local result = finger.str:sub(finger.pos, 1)
                        finger.pos = finger.pos + 1
                        if result ~= '$' then return result end
                        if not expanding then return result end
                        -- oh oh, possible macro invocation
                        local next_char = this:get_char(false)
                        if next_char == nil or next_char == '$' then return '$' end
                        error("need to handle macro invocation!")
                    end
                end
            end
            return nil
        end
    }
end

blud.phase3 = {}
function blud.phase3:looks_like_macro_assign(line)
    local name, operator, body_pos = line:match("^(%a[%w_]*)%s*([=+:])()")
    if name and operator and body_pos then
        local next_char = line:sub(body_pos, body_pos)
        if operator == ":" then
            if next_char ~= '=' then return nil end
            operator = ":="
            body_pos = body_pos + 1
        elseif operator == "+" then
            if next_char ~= '=' then
                 error("Unexpected '+': " .. line )
            end
            operator = "+="
            body_pos = body_pos + 1
        elseif operator == '=' then
            -- it's just a simple '=' operator (anything after is part of body!)
        else
            assert(false)
        end
        local _, _, body_pos = line:find("^[ \t]*()", body_pos)
        return { line=line, name=name, operator=operator, body_pos=body_pos }
    end
    return nil
end

function blud.phase3:macro_assign(macro)
    print("expand_macro_assign got: ", dump(macro))
    return macro.name .. macro.operator .. macro.body
end

function blud.phase3:looks_like_dependency_line(text)
    -- ??? make better!
    local match = text:match("^[^%s].*:")
    return match ~= nil
end

function blud.phase3:looks_like_empty_line(text)
    -- handle comments
    match = string.find(text, "^%s*$")
    return match ~= nil
end

function blud.phase3:looks_like_action_line(text)
    -- handle comments
    local match = string.find(text, "^%s+")
    return match ~= nil
end

function blud.phase3:looks_like_build_line(text)
    -- handle comments
    if text:find("^build%s*$") or text:find("^build%s+") then
        return true
    else
        return valse
    end
end

function match_quoted_string(text, start_pos)
    local quote_char = text:sub(start_pos, start_pos)
    if quote_char ~= '"' and quote_char ~= "'" then
        return nil, "Not a quote character at start_pos"
    end

    local i = start_pos + 1
    local len = #text
    local escaped = false

    while i <= len do
        local char = text:sub(i, i)
        if char == "\\" and not escaped then
            escaped = true
        elseif char == quote_char and not escaped then
            return text:sub(start_pos, i), i + 1
        else
            escaped = false
        end
        i = i + 1
    end

    return nil, "Unterminated quoted string"
end

function match_colon_operator(text, pos)
    local match = text:match("^:%a*:", pos)
    if match then
        return text:sub(pos, pos + #match - 1)
    end
    return ":"
end

function blud.phase3:tokenize(line)
    local pos = 0
    local token
    local tokens = {}    
    while pos < #line do
        pos = pos + 1
        local char = line:sub(pos, pos)
        if char:find("%s") then   -- if char is white space
            token = " "
        elseif char:find("[\'\"]") then -- if char is a quote
            token = match_quoted_string(line, pos)
            table.insert(tokens, token)
        elseif char == ":" then
            token = match_colon_operator(line, pos)
            table.insert(tokens, token)
        else
            local pattern = "^[^%s:\"\']*"  -- match an atom/path
            token   = line:match(pattern, pos)
            table.insert(tokens, token)
            assert(#token > 0)
        end
        pos = pos + #token - 1
    end
--    print("tokenized line: " .. dump(tokens))
    return tokens
end

-- variables have been expanded, we have line of the form <targets> <colon_operator> <prerequisites>
function blud.phase3:compile_rule(dependency_line, action)
print("********************* compile_rule")
    local tokens = blud.phase3:tokenize(dependency_line)
    local targets = {}
    local prerequisites = {}
    local token_pos = 1
    local token     = ""
    while token_pos <= #tokens do
        token = tokens[token_pos]
        if token:sub(1,1) == ':' then
            break
        else
            table.insert(targets, token)
        end
        token_pos = token_pos + 1
    end
    assert(token:sub(1,1) == ":")
    local colon_operator = token
    token_pos = token_pos + 1
    while token_pos <= #tokens do
        token = tokens[token_pos]
        if token:sub(1,1) == ":" then
            error("more than one colon operator on line!")
        else
            table.insert(prerequisites, token)
        end
        token_pos = token_pos + 1
    end
    blud.add_rules(colon_operator, targets, prerequisites, action)
end

function blud.phase3:parse()
    print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!phase2_text!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
    print(blud.phase2_text)
    print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!END phase2_text!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
    local get_line          = blud.lines(blud.phase2_text)
    local action_legal_here = false
    local line              = get_line()
    local inside_build      = false
    self.text = {}
    while line do
        assert(line ~= nil)
        local macro = self:looks_like_macro_assign(line)
        if macro then
            line = blud.macro_assign(line, blud.scope_bludfile, macro)
            table.insert(self.text, line .. "\n")
            line = get_line()
        elseif self:looks_like_dependency_line(line) then
            local dependency_line = blud.macro_expand_text(blud.scope_bludfile, line)
            table.insert(self.text, dependency_line .. "\n")
            local action = ""
            line = get_line()
            if line then
                while self:looks_like_action_line(line) do
                    action = action .. line .. "\n"
                    table.insert(self.text, line .. "\n")
                    line = get_line()
                    if not line then break end
                end
            end
            blud.phase3:compile_rule(dependency_line, action)
--            line = get_line()
        elseif self:looks_like_empty_line(line) then
            table.insert(self.text, line .. "\n")
            line = get_line()
        elseif self:looks_like_build_line(line) then
            local build_name = line:match("^build%s+(%a+)")
            if not build_name then
                error("Bad build directive syntax: " .. line)
            end
            if inside_build then error("Can't nest 'build' directives.") end
            if not blud.build_name then
                blud.build_name = build_name
            end
            line = get_line()
            if build_name ~= blud.build_name then
                while line and not line:find("^end%s*$") do
                    line = get_line()
                end
                if not line then error("Missing 'end' for build directive.") end
            else
                inside_build = true
            end
        elseif line:find("^end%s*$") then
            if not inside_build then error("extraneous 'end'") end
            inside_build = false
            line = get_line()
        else
            error("wtf: '" .. line .. "'")
        end
    end
    print(table.concat(self.text))
end


--[=[
blud.phase3       = function ()
    print(blud.phase2_text)
    local get_line          = blud.lines(blud.phase2_text)
    local action_legal_here = false
    local line              = get_line()
    while line do
        if looks_like_macro_assign(line) then
            

        local char = input_stack:get_char()
        if not char then break end
        if state == "START" then
            if 
        end
    end
    while input_stack do
        local input = input
    end

    for i = 1, #blud.phase2_text do
        local c = blud.phase2_text:sub(i, 1)
--        if c == '$' then
    end

    for line in blud.lines(blud.phase2_text) do
        print("Line is: " .. line )
        local macro_name, operator, text = blud.match_macro_assign(line)
        if macro_name then
            blud.macro_assign(macro_name, operator, text)
            print(macro_name .. operator .. text)
        elseif blud.match_dependency(line) then
            
        end
    end
end
]=]

blud.current_time = os.time()
blud.shallow_copy = function (original)
    local copy = {}
    for key, value in pairs(original) do
        copy[key] = value
    end
    return copy
end
blud.dump_atom = function (atom)
    local str = atom.NAME .. " : "
    local prerequisites = atom.PREREQUISITES
    if prerequisites ~= nil then
        for key, value in pairs(prerequisites) do
            str = str .. " " .. value.NAME
        end
    end
    return str
end

-- define super atom (a metatable), which contains defaults for all atoms

blud.global = {
    -- BIND: associate an atom with an actual filename
    BIND  = function(atom)
        -- ???
        return atom
    end,
    }
blud.super_atom = {
    NAME = "",
    ADD_PREREQUISITE = function(target, prerequisite)
        print("ADD_PREREQUISITE(" .. target.NAME .. ", " .. prerequisite.NAME .. ")")
        local prerequisites = target.PREREQUISITES
        if prerequisites ~= nil then
            table.insert(prerequisites, prerequisite)
        else
            target.PREREQUISITES = { prerequisite }
        end
        -- an attribute gets inserted into the prototype chain of its prerequisite
        if target.ATTRIBUTE == true then
            -- a copy, because attributes are not singletons
            local target_copy = blud.shallow_copy(target)
            target_copy.ATTRIBUTE_TARGET = prerequisite
            setmetatable(target_copy, getmetatable(prerequisite))
            target_copy.__index = target_copy
            setmetatable(prerequisite, target_copy)
        end
    end,
    ADD_RULE = function(target, prerequisites, action)
        print("super_atom ADD_RULE target = " .. dump(target) .. ": " .. dump(prerequisites))
        if type(action) == 'string' and action ~= '' then
            if target.ACTION then
                error("Target " .. target.NAME .. " already has an action: " .. target.ACTION)
            else
                target.ACTION = action
            end
        end
        if prerequisites ~= nil then
            for _, prerequisite in ipairs(prerequisites) do
                target.ADD_PREREQUISITE(target, prerequisite)
            end
        end
    end,
    SOURCE_RULE = function(target, prerequisites, action)
        print("super_atom SOURCE_RULE target = " .. dump(target) .. ": " .. dump(prerequisites))
        if type(action) == 'string' and action ~= '' then
            if target.ACTION then
                error("Target " .. target.NAME .. " already has an action: " .. target.ACTION)
            else
                target.ACTION = action
            end
        end
        if prerequisites ~= nil then
            for _, prerequisite in ipairs(prerequisites) do
                if prerequisite.NAME:sub(-2) == ".c" then
                    print("handle source ", prerequisite.NAME)
                    local obj = prerequisite.NAME:gsub("%.c$", ".o")
                    local obj_target = blud.get_or_create_target(obj)
                    target.ADD_RULE(target, { obj_target } )
                    target.ADD_RULE(obj_target, {prerequisite}, [[
$(CC) $(CFLAGS) -o $(OWD)/$<
]])
                else
                    error("don't know how to handle " .. prerequisite.NAME)
                end
--                target.ADD_PREREQUISITE(target, prerequisite)
            end
        end
    end,
    APPLY_SPECIAL = function(atom, prerequisites)
        print("APPLY_SPECIAL " .. dump(atom))
        for _, prerequisite in ipairs(prerequisites) do
            
        end
    end,
    -- BIND: associate an atom with an actual filename
    BIND  = function(atom)
        --
        print("bind atom: " .. dump(atom))
        return atom
    end,
    BUILD = function(target)
        print("BUILD('" .. blud.dump_atom(target) .. "')")
        if target.PARENT then print("PARENT('" .. blud.dump_atom(target.PARENT) .. "')") end
        if target.BUILDING == true then
            error("circular dependency on " .. target.NAME)
        end
        target.BUILDING = true
        target.BUILD_PREREQUISITES(target)
        local timestamp = blud.get_fs_timestamp(target.NAME)
        print("timestamp for '" .. target.NAME .. "' is " .. timestamp)
        if timestamp < blud.current_time then
            if target.ACTION then
                print("execute: '" .. target.ACTION .. "'")
--                print(" meta is " .. dump(getmetatable(target)))
                target:DO_ACTION()
            end
        end
        target.BUILDING = false
        return true   -- default is to pretend we successfully built it
    end,
    BUILD_PREREQUISITES = function(atom)
        print("BUILD_PREREQUISITES('" .. blud.dump_atom(atom) .. "')")
        local prerequisites = atom.PREREQUISITES;
--        print("prereqs: " .. dump(prerequisites))
        if prerequisites then
            for _, prereq_name in ipairs(prerequisites) do
                prerequisite = atom.BIND(prereq_name)
                prerequisite.PARENT = atom
                prerequisite.BUILD(prerequisite)
            end
        end

    end,
    DO_ACTION = function(target)
        if target.SCOPE == nil then
            target.SCOPE = blud.ScopeTarget:new(target)
        end
        local exit_code
        print("DO_ACTION in super atom for " .. target.NAME)
        local action = blud.macro_expand_text(target.SCOPE, target.ACTION)
print("expanded action is ", action)
        print( [[ exit_code = os.execute(action) ]] )
        if exit_code then
            error("command failed: " .. action)
        end
    end,
}

setmetatable(blud.super_atom, blud.global)
blud.global.__index      = blud.global
blud.super_atom.__index  = blud.super_atom

blud.new_atom = function(atom_name)
    local atom = {}
    -- atom must always have a name
    atom.NAME  = atom_name
    -- atom must always have a prerequisite list, even if it is empty
    -- this guarantees prerequisites are not inherited
    atom.PREREQUISITES = {}
    -- the initial metatable for an atom is the "super atom", which
    -- provides the default behavior
    return setmetatable(atom, blud.super_atom)
end
blud.is_special_atom = function(atom)
    return string.sub(atom.NAME, 1, 1) == "."
end

blud.set_callback = function(target, hook_name, callback_func)
print("set_callback(" .. target.NAME .. ", " .. hook_name .. ")")
    -- make new metatable whose metatable is target metatable
    local new_meta      = setmetatable({}, getmetatable(target))
    new_meta.__index    = new_meta
    -- new metatable will call callback_func for this particular hook
    new_meta[hook_name] = callback_func
    -- finally, insert new metatable before target's metatable
    setmetatable(target, new_meta)
end

blud.TARGETS = {
    [ ".AFTER" ] = {
        NAME = ".AFTER",
        ATTRIBUTE = true,
        DO_ACTION = function(target, prerequisites, action)
            local after = function()
                status, exit_code = os.execute(target.ATTRIBUTE_TARGET.ACTION)
            end
            blud.set_callback(target.PARENT, "DO_ACTION", after)
            return true
        end
    },
    [ ".GLOBAL_MACRO" ] = {
        NAME = ".GLOBAL_MACRO",
        ATTRIBUTE = true,
    }
}

for atom_name, atom in pairs(blud.TARGETS) do
    setmetatable(atom, blud.super_atom)
end

blud.get_fs_timestamp = function (filepath)
    local command = string.format("stat -c %%Y '%s' 2>/dev/null", filepath)
    local pipe = io.popen(command, "r")
    local output = pipe:read("*a")
    pipe:close()

    -- Convert the timestamp to a number
    local timestamp = tonumber(output)
    if not timestamp then
        print("Failed to get timestamp for file: " .. filepath)
        timestamp = 0
    end
    return timestamp
end

blud.add_rule = function(target, prerequisites, action)
    print("add_rule('" .. target.NAME .. "' :" .. #prerequisites .. ")")
    if action ~= nil then
        if target.ACTION then
            error("Target " .. target.NAME .. " already has an action")
        else
            target.ACTION = action
        end
    end
    -- target may already have prerequisites, these will be added
    -- note that we do not dedup, since duplicates could be significant
    -- in the general case.
    local prerequisites = target.PREREQUISITES or {}
    for _, dep in ipairs(prerequisites) do
        print("    ." .. dep)
        table.insert(prerequisitess, dep)
    end
    target.PREREQUISITES = prerequisites
end

blud.operators[":"] = function(colon_operator, target, prereq_atoms, action)
    return target:ADD_RULE(prereq_atoms, action)
end

blud.operators["::"] = function(colon_operator, target, prereq_atoms, action)
    return target:SOURCE_RULE(prereq_atoms, action)
end

blud.operators[":BUILD:"] = function(colon_operator, target, prereq_atoms, action)
    print("Do :BUILD: for target " .. target.NAME .. " with " .. #prereq_atoms .. " args ")
    -- determine value of OWD
    local owd = target.NAME
    if #prereq_atoms > 0 then
        owd = prereq_atoms[1].NAME
    end
    -- is this the default build (first one mentioned?)
    if blud.BUILD_DEFAULT == nil then
        blud.BUILD_DEFAULT = target
        print("default build is: ", blud.BUILD_DEFAULT.NAME)
    end

    -- need to give .GLOBAL_MACRO attribute to target
end

blud.add_rules = function(colon_operator, targets, prerequisites, action)

print("blud.add_rules targets = " .. dump(targets) .. tostring(colon_operator) .. dump(prerequisites))

    local prereq_atoms = {}
    for _, prereq_name in ipairs(prerequisites) do
        local prerequisite = blud.get_or_create_target(prereq_name)
        table.insert(prereq_atoms, prerequisite)
    end
    for _, target_name in ipairs(targets) do
        local target = blud.get_or_create_target(target_name)
        if blud.primary_targets == nil then
            blud.primary_targets = { target }
        end
        local operator = blud.operators[colon_operator]
        if operator == nil then
            errorf("'#1': undefined operator.", colon_operator)
        end
        operator(colon_operator, target, prereq_atoms, action)
--        target.ADD_RULE(target, prereq_atoms, action)
    end
end


blud.build = function(target, parent_atom)
    print("[[[[[[[[[build " .. target.NAME .. "]]]]]]]]")
    blud.global.BIND(target)
    target.PARENT = parent_atom
    target:BUILD_PREREQUISITES()
    return target:BUILD()
end

blud.get_or_create_target = function(target_name)
    local target = blud.TARGETS[target_name]
    if target == nil then
        target = blud.new_atom(target_name)
        blud.TARGETS[target_name] = target
        blud.PREREQUISITES = {}
    end
    return target
end

-- build
blud.run_build = function(primary_target)
    local targets = {}
--    print("blud " .. primary_target)
    table.insert(targets, blud.get_or_create_target(primary_target))
--    print("before for: Type of blud.build:", type(blud.build)) 
    for _, target in ipairs(targets) do
        target:BUILD()
    end
end

]==]

local function dump(o)
    if type(o) == 'table' then
        local s = '{ '
        for k,v in pairs(o) do
            if type(k) ~= 'number' then k = '"'..k..'"' end
            if v ~= "__index" then
                s = s .. '['..k..'] = ' .. dump(v) .. ','
            end
        end
        return s .. '} '
    else
        return tostring(o)
    end
end


function template(str, values)
    return (str:gsub("{(.-)}", function(key)
                         return values[key] or "{" .. key .. "}"
    end))
end



blud_primary_target_name = ""


blud_user_code = ""


-- returns generator that lets you read/peek one line at a time from the file
function buffered_line_io(file)
    local current_line; --  = file:read("*l")  -- Read the first line to prime the generator
    local has_peeked   = false
    local peek_line    = nil

    return function(peek)
        if peek then
            if has_peeked then
                return peek_line  -- Return the peeked line without advancing
            else
                peek_line  = file:read("*l")
                has_peeked = true
                return peek_line
            end
        else
            if has_peeked then    -- We've peeked, now consume that line
                has_peeked   = false
                current_line = peek_line
                peek_line    = nil
            else                -- No peek happened, move to the next line
                current_line = file:read("*l")
            end
            return current_line
        end
    end
end

function calculate_indent(line)
    if line == nil then return 0 end
    local indent = 0
    for i = 1, #line do
        local char = line:sub(i, i)
        if char == ' ' then
            indent = indent + 1
        elseif char == '\t' then
            indent = indent + 4
        else
            break
        end
    end
    --    print("indent of '" .. line .. "' = " .. indent);
    return indent
end

function atoms_to_string(atoms)
    local result = ""
    for _, name in ipairs(atoms) do
        if result ~= "" then result = result .. ", " end
        result = result .. name
    end
    return result
end

function line_is_lua(line)
    local result     = true
    local keywords   = {
        ["do"]       = true,
        ["else"]     = true,
        ["elseif"]   = true,
        ["end"]      = true,
        ["for"]    = true,
        ["function"] = true,
        ["if"]       = true,
        ["local"]    = true,
        ["repeat"] = true,
        ["then"]   = true,
        ["until"]  = true,
        ["while"]  = true,
    }
    local first_word = line:match("^%a+")
    if first_word ~= nil then
        if keywords[first_word] == nil then
            result = false
        end
    end
    return result
end

function match_macro_assign(line)
    local operators = {
        ["="]   = true,
        [":="]  = true,
        ["+="]  = true,
    }
    --    print("match_macro_assign(\"" .. line .. "\")")
    local pattern = "^(%a+)%s*([=+:]+)%s*(.*)$"
    macro_name, operator, remainder = line:match(pattern)
    if macro_name and operator then
        if operators[operator] == true then
            return macro_name, operator, remainder
        end
    end
    return nil
end

function lua_quote(str)
    -- Escape backslashes and double quotes
    str = str:gsub("\\", "\\\\"):gsub('"', '\\"')
    
    -- Replace special characters
    str = str:gsub("\n", "\\n")
        :gsub("\r", "\\r")
        :gsub("\t", "\\t")
        :gsub("\b", "\\b")
        :gsub("\f", "\\f")
    
    -- Wrap the string in double quotes
    return '"' .. str .. '"'
end

function emit_macro_assign(macro_name, operator, remainder)
    local variables = {
        macro_name = lua_quote(macro_name),
        operator   = lua_quote(operator),
        remainder  = lua_quote(remainder)
    }
    local script = [[
blud.macro_assign({macro_name}, {operator}, {remainder})
]]
local var =  script:gsub("{(.-)}", variables)
print(var)
end

function leading_keyword(line)
    local result = nil
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

    local keyword = line:match("^%a+")
    if keyword == "local" and line:match("local%s+function%s+") then
        keyword = "function"
    end
    if keywords[keyword] then result = keyword end
    return result
end

function syntax_error(line, line_number, format_string, ...)
    io.stderr:write(line)
    io.stderr:write("\n^^^^\n")
    io.stderr:write(string.format("Error on line %d: ", line_number))
    if format_string then
        local args = {...}
        local message = format_string:gsub("#(%d+)", function(n)
                                               return tostring(args[tonumber(n)])
        end)
        io.stderr:write(message)
    end
    io.stderr:write("\n")
    os.exit(1)
end

-- handle a Lua line that might have embedded make code
-- ??? does not handle embedded $(name a b "c" "d()")
function phase1_embedded_make(line)
    local code = line:match("^%s*$ (.*)$")
    if code then
        line = "blud.phase2_append(" .. lua_quote(code) .. ")"
    end
    return line
end

function phase1_line_is_empty(line)
    if line:find("^%s*$") then
        return true
    elseif line:find("^%s*%-%-[^[]") then
        return true
    elseif line:find("^%s*%-%-") then
        return true
    else
        return false
    end
end

function phase1_pass(get_line)
    local line_number   = 0
    local line
    local text          = ""
    local open_keyword  = nil
    local default_build = nil
    local error = function (...)
        syntax_error(line, line_number, ...)
    end

    while true do
        ::NEXT::
        line_number = line_number + 1
        line = get_line(false)
        if line == nil then break end -- end of file
        if phase1_line_is_empty(line) then goto NEXT end
        local keyword = leading_keyword(line)
        if not keyword then
            if open_keyword then   -- copying Lua code ??? handle embedded make code
                line = phase1_embedded_make(line)
            else -- copying non-Lua code
                line = "blud.phase2_append(" .. lua_quote(line) .. ")"
            end
        elseif keyword == "do" or keyword == "function" or keyword == "if" or keyword == "repeat" then
            if open_keyword then error("already inside '#1'", open_keyword) end
            open_keyword = keyword
        elseif keyword == "end" then
            if not open_keyword then
                error("Unexpected 'end'")
            else
                open_keyword = nil
            end
        elseif keyword == "elseif" or keyword == "else" then
            if open_keyword ~= "if" and open_keyword ~= "elseif" then
                error("Unexpected '#1' doesn't match open '#2'", keyword, open_keyword)
            else
                open_keyword = keyword
            end
        elseif keyword == "local" then
            -- just copy the line
        else
            line =  "blud.phase2_append(" .. lua_quote(line) .. ")"
        end
        text = text .. line .. "\n"
    end
    return text
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

function preprocess(get_line)
    local previous_indent   = 0

    while true do     -- for line in file:lines() do
        local line = get_line(false)
        if line == nil then break end
        local macro_name, operator, remainder = match_macro_assign(line)
        if macro_name then
            emit_macro_assign(macro_name, operator, remainder)
        else
        end
        if false then
            if not line_is_lua(line) then
                blud_user_code = blud_user_code .. "do -- " .. line .. "\n"
                local targets, prerequisites = process_make_rule(line) 
                local indent = calculate_indent(line)
                local action = ""
                while calculate_indent(get_line(true)) > indent do
                    action = action .. get_line(false) .. "\n"
                end
                blud_user_code = blud_user_code .. "    blud.add_rules(targets, prerequisites, "
                if action == nil then
                    blud_user_code = blud_user_code .. "nil)\n"
                else
                    blud_user_code = blud_user_code .. "[[" .. action .. "]])\n"
                end
                
                blud_user_code = blud_user_code .. "end "
            else -- line is Lua, but could be extended by comment or quoted string
                while true do
                    blud_user_code = blud_user_code .. line .. '\n'
                end
            end
        end
    end
end

function process_make_rule(line)
    local targets       = {}
    local prerequisites = {}

    -- Split the line at the colon
    local target_part, prerequisite_part = line:match("^%s*(.-)%s*:%s*(.*)")

    -- Check and split the target part into paths
    blud_user_code = blud_user_code .. "    local targets = { "
    for target in target_part:gmatch("%S+") do
        blud_primary_target_name = blud_primary_target_name or target
        table.insert(targets, target)
        blud_user_code = blud_user_code .. '"' .. target .. '"'
    end
    blud_user_code = blud_user_code .. " }\n"

    -- Check and split the prerequisite part into paths
    blud_user_code = blud_user_code .. "    local prerequisites = { "
    for prerequisite in prerequisite_part:gmatch("%S+") do
        table.insert(prerequisites, prerequisite)
        blud_user_code = blud_user_code .. '"' .. prerequisite .. '"'
    end
    blud_user_code = blud_user_code .. " }\n"

    --[=[
        local code = [[    blud.add_dependents(targets, prerequisites)
        ]]

        for _, target in ipairs(targets) do
        local atom_list = ""
        for _, prerequisite in ipairs(prerequisites) do
        atom_list = atom_list .. "," .. prerequisite
        end
        code = code:gsub("{target}", target);
        code = code:gsub("{atom_list}", atom_list);
        blud_user_code = blud_user_code .. code
        end
    ]=]

    return targets, prerequisites
end


--[[
    local file = io.open("blud", "r")
    assert(file)
    local blud_file_text = file:read("*a")
    file:close()
]]

function get_bludfile_path()
    local path = "bludfile"
    local args = COMMAND_LINE
    local option = "-f"
    for i = 1, #args do
        if args[i] == option then
            -- Check if there's a next argument to be the value
            if i < #args then
                return args[i + 1]
            else
                return path
            end
        end
    end
    return path
end


print("start executing phase 1")
local bludfile_path = get_bludfile_path()
local luac_path = bludfile_path .. ".luac"
local blud_exe_path = get_executable_path()
assert(blud_exe_path ~= nil)
local blud_exe_timestamp = get_path_timestamp(blud_exe_path)
local bludfile_timestamp = get_path_timestamp(bludfile_path)
local luac_timestamp     = get_path_timestamp(luac_path)

local luac_needs_building = true
if bludfile_timestamp ~= nil and luac_timestamp ~= nil then
    if blud_exe_timestamp < bludfile_timestamp and blud_exe_timestamp < luac_timestamp then
        if bludfile_timestamp < luac_timestamp then
            luac_needs_building = false
        end
    end
end

--print(phase1_text)
local final_code = [[
blud.phase3:parse()
if blud.primary_targets == nil then
    error("No targets to build!")
else
    blud.build_init()
    for _, target in ipairs(blud.primary_targets) do
        target:BUILD()
    end
end
]]


if luac_needs_building then

    file = io.open(bludfile_path)
    --file = io.stdin
    --preprocess(buffered_line_io(file))
    local phase1_text = phase1_pass(buffered_line_io(file))
    file:close()
    --print(blud_module_code)
    print("phase 1 complete")

    local code_to_compile = blud_module_code .. "\n" .. phase1_text .. "\n" .. final_code


    if not blud_primary_target_name  then
        print("No target given to build")
    else
        print("building '" ..  blud_primary_target_name .. "'")
        print( dump( blud_primary_target_name))
    end

    blud_user_code = blud_user_code .. "\nblud.run_build(\"" .. blud_primary_target_name .. "\")\n"

    -- Compile the source code to bytecode
    local compiled_function, err = loadstring(code_to_compile)
    if not compiled_function then
        print("Failed to compile source code: " .. err)
        return
    end

    local bytecode = string.dump(compiled_function, false) -- true to strip debugging info

    -- Save the bytecode to a file
    local luac_path = bludfile_path .. ".luac"
    local file = io.open(luac_path, "wb")
    if file then
        file:write(bytecode)
        file:close()
        print("Bytecode saved to " .. luac_path)
    else
        print("Failed to open file for writing")
    end
else
    print("using pre-compiled bludfile!")
end

function execute_bytecode(file_path)
    -- Open the bytecode file
    local file, err = io.open(file_path, "rb")
    if not file then
        print("Failed to open file: " .. err)
        return
    end

    -- Read the bytecode
    local bytecode = file:read("*all")
    file:close()

    -- Load the bytecode
    local func, load_err = load(bytecode)
    if not func then
        print("Failed to load bytecode: " .. load_err)
        return
    end

    -- Execute the bytecode and trap errors
    local status, exec_err = pcall(func)
    if not status then
        print("Error executing bytecode: " .. exec_err)
    end
end

-- Example usage
execute_bytecode(luac_path)


--print(blud_user_code);

--[[
    function lines_length(input, line_number)
    if line_number >= 1 then
    local current_line = 1
    local position = 1

    -- Repeat finding new lines until the desired line
    while true do
    if current_line == line_number then
    return position
    end
    local start_pos, end_pos = string.find(input, "\n", position)
    if not start_pos then
    break  -- No more newlines found
    end
    current_line = current_line + 1
    position     = end_pos + 1
    end
    end
    return nil  -- Line number does not exist in the input
    end


    function parse_blud_file_text(source_text)
    local lua_text  = ""
    local func, error_message = loadstring(source_text)
    local line, message = error_message:match(":(%d+):%s*(.*)")
    if error_message then
    print("line " .. line .. ": " .. message)
    assert(false)
    end
    end
    parse_blud_file_text(blud_file_text)
    assert(false)
]]

--[[
    function report_error(error_message, code)
    print("Error ", error_message)
    -- Extracting the line number from the error message
    local lineNumber = tonumber(error_message:match(":(%d+):"))
    if lineNumber then
    -- Splitting the code into lines and printing the problematic line
    local lines = {}
    for line in code:gmatch("([^\n]*)\n?") do
    table.insert(lines, line)
    end
    print("Error at line", lineNumber, ":", lines[lineNumber])
    end

    end


    local program = blud_module_code .. blud_user_code
    local func, err = loadstring(program)
    print("back from loadstring")
    if func then
    status, err = pcall(func)
    if not status then
    report_error(err, program);
    end
    else
    report_error(err, program);
    end
]]

