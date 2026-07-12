--blud_module_code = [==[


-- parts      := { part* }
-- part       := string | macro_call
-- macro_call := { macro=true, eval="delay"|"immediate" stack_frame }
-- stack_frame:= [1] = parts, [2] = parts, ...


--[[
text
    Raw uninterpreted input text from a line or action body.

part
    A parsed piece of text before macro expansion is complete.
    Either:
        - a string/text fragment
        - a table representing a macro invocation

token
    A whitespace-delimited string after macro expansion/tokenization.
    It has not been globbed.
    It should not yet be assumed to name an atom.

name
    A string that has passed operator-specific interpretation.
    It is intended to become an atom.NAME.
    Glob expansion, path-prefixing, implicit naming rules, etc. produce names.

atom
    A table with at least:
        NAME = name
    May also contain PREREQUISITES, ACTION, TYPE, BOUND_NAME, etc.
--]]

-- Insert custom loader at the beginning of package.loaders
table.insert(package.loaders, 1, function(modname)
    local filename = modname .. ".lua"
    local code = CSTRGet(filename)
    if code then
        -- Load the code and return the module function
        return assert(loadstring(code, "@" .. filename))
    else
        -- Return nil and an error message to continue to the next loader
        return nil, "\n\tmodule '" .. modname .. "' not found in embedded strings"
    end
end)

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


local function dump1(o)
    if type(o) == 'table' then
        local s = '{ '
        for k,v in pairs(o) do
            if type(k) ~= 'number' then k = '"'..k..'"' end
            if v ~= "__index" then
--                s = s .. '['..k..'] = ' .. dump(v) .. ','
                s = s .. '['..k..'] = ' .. tostring(v) .. ','
            end
        end
        return s .. '} '
    else
        return tostring(o)
    end
end
local function formatValue(value)
    if type(value) == "string" then
        if #value > 100 then
            return string.format("%q", value:sub(1, 100) .. "... (truncated)")
        else
            return string.format("%q", value)
        end
    elseif type(value) == "number" or type(value) == "boolean" then
        return tostring(value)
    elseif type(value) == "table" then
--        return "{table}"
        return dump1(value)
    else
        return tostring(value)
    end
end

local function getFunctionParameters(level)
    local params = {}
    local i = 1
    while true do
        local name, value = debug.getlocal(level+1, i)
        if not name then break end
        -- Stop at first local variable that is not a function parameter
        if name:match("^%(") then break end
        table.insert(params, {name = name, value = value})
        i = i + 1
    end
    return params
end

function getDetailedTraceback()
    local level = 3 
    local traceback = {"Stack traceback:"}

    while true do
        local info = debug.getinfo(level, "Sln")
        if not info then break end

        local params = getFunctionParameters(level)
        local frame = string.format("  Function '%s' at %s:%d", info.name or "unknown", info.short_src, info.currentline)
        table.insert(traceback, frame)

        for _, param in ipairs(params) do
            table.insert(traceback, string.format("    %s = %s", param.name, formatValue(param.value)))
        end

        level = level + 1
        if level > 6 then break end
    end

    return table.concat(traceback, "\n")
end

function error_with_traceback(fmt, ...)
    local message = string.format(fmt, ...)
    local traceback = getDetailedTraceback()
    error(message .. "\n" .. traceback, 2)
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
--    io.stderr:write(debug.traceback("", 2))
    io.stderr:write(getDetailedTraceback())
    error("", 2)
--    os.exit(1)
end

function glob_words(input)  -- ?? must it be global???
--    util.print("glob_words(%s)", util.dump(input))
    local output = {}

    for _, word in ipairs(input) do
        if is_pattern(word) then
            blud.glob.expand_pattern(output, word)
        else
            table.insert(output, word)
        end
    end

    return output
end

--[[
    build_stack - stack of targets currently being built

    .target - target (atom) being built in this frame
blud.build_stack = {}
--]]


blud.debugger = require("debugger")
if blud.command_line_options.debug == true then
    blud.debugger.probe = blud.debugger.real_probe
end
blud.Macro = require("macro")

blud.rules          = {}

blud.default_action = function (scope)
    blud.execute(scope, nil)
end


blud.execute = function(scope, text)
    -- util.print("blud.execute(text=%s)", util.dump(text))
    assert(type(text) == "string")
    local status
    if text then
        print(text)
        status = os.execute(text)
        -- print("    status = ", status)
    else
        -- print("<no action>")
    end
    
    return status
end

blud.eval_target_assign_rule = function(left_parts, macro, action)
    if action then
        error("Can't have action on target-specific assignment")
    end
    local left  = blud.Macro.expand_tokens(blud.Scope.bludfile, left_parts)
    local target_names = tokenize_dependency_line(left)

    for i = 1, #target_names do
--        util.print("%s: %q %s %q",
--                   target_names[i], macro.name, macro.operator, macro.macro_text)
        local target = blud.get_or_create_target(target_names[i])
        target:set_variable(macro)
    end
end


-- eval_rule does minimal processing then goes into the operator hook system
blud.eval_rule = function(operator_name, left_parts, right_parts, action)
--[[
    util.print("blud.eval_rule, %s, %s, %s, action",
               util.dump(operator_name),
               util.dump(left_parts),
               util.dump(right_parts))
--]]
    -- now is the time to identify implicit rules
    -- note that "%" hidden inside macro call is a literal
    if operator_name == ":" then
        for i=1, #left_parts do
            local part = left_parts[i]
            if type(part) == 'string' and part:find("%", 1, true) then
                operator_name = "%:"
                break
            end
        end
        if operator_name == ":" and #right_parts > 0 then
            local macro = blud.Macro.match_macro_assign(right_parts[1], true)
            if macro then
                return blud.eval_target_assign_rule(left_parts, macro, action)
            end
        end
    end
    local operator = blud.operators[operator_name]
    if not operator then
        blud.error("Unknown operator: #1", operator_name)
    end
    -- everybody wants their macros expanded, you can't override this
    local left  = blud.Macro.expand_tokens(blud.Scope.bludfile, left_parts)
    local right = blud.Macro.expand_tokens(blud.Scope.bludfile, right_parts)

    -- seems sketchy for some operators to tokenize differently, so do that here
    local target_names = tokenize_dependency_line(left)
    local prereq_names = tokenize_dependency_line(right)

    operator:EVAL_RULE(target_names, prereq_names, action)
end

function blud.macro(name, ...)
    local macro_call = { { tostring(name) } }

    for i = 1, select("#", ...) do
        table.insert(macro_call, { tostring(select(i, ...)) })
    end

    local result = blud.Macro.expand_call(blud.scope_bludfile, macro_call)
    return table.concat(result)
end

M = blud.macro

blud.implicit        = require("implicit")
--blud.sourcemap       = require("sourcemap")
blud.error           = errorf
blud.assert          = function(condition, format, ...)
    if not condition then
        if format then
            blud.error(format, ...)
        else
            blud.error("assertion failed.")
        end
    end
end
blud.dir_cache       = {}
blud.operators       = {}
blud.build_name      = nil
blud.default_target  = nil
blud.primary_targets = nil
blud.array_append    = function(array, more)
    if not (type(array) == "table" and type(more) == "table") then
        blud.error("Bad call to array_append")
    end
    for _, element in ipairs(more) do
        table.insert(array, element)
    end
end

blud.insert_stem = function(pattern, stem)
    return pattern:gsub("%%", stem)
end
blud.match_rule = function(pattern, target)
    -- Escape any special Lua pattern characters, except for '%'
    local escaped_pattern = pattern:gsub("([%.%^%$%(%)%%%[%]%+%-%?])", "%%%1")

    -- Replace '%' in the pattern with '(.*)' to capture the stem
    local lua_pattern = escaped_pattern:gsub("%%", "(.*)")

    -- Use string.match to attempt to match the target with the modified pattern
    local stem = string.match(target, lua_pattern)
    
    -- Return the stem if found, otherwise return nil
    return stem
end
blud.implicit_rules = {}
blud.find_reverse_rule = function(prerequisite_name)
    for i = #blud.implicit_rules, 1, -1 do
        local rule = blud.implicit_rules[i]
        local stem = blud.match_rule(rule.prerequisites[1].NAME, prerequisite_name)
        if stem then
            return stem, rule
        end
    end
    return nil
end

blud.glob = {}
-- Main function to expand the glob pattern
function blud.glob.expand_pattern(words, pattern)
    assert(type(pattern) == 'string', "expand_pattern expecting string argument")
    -- Split the pattern into path components
    local path_components = blud.glob.path_split(pattern)
    local dir = path_components[1]  -- Start with the root directory (or "." for current directory)

    -- Create a temporary table to store the new results
    local new_words = {}

    -- Call the recursive helper function to match the pattern, starting with an empty path
    local initial_cache = blud.glob.get_cached_dir(dir)  -- Cache for the root directory
    local match_count   = blud.glob.recursive_glob_match(new_words, path_components, 2, "", initial_cache)  -- Empty path

    -- If no matches were found, treat the pattern as a literal and add it to 'new_words'
--    if match_count == 0 then
--        table.insert(new_words, pattern)
--    end

    if match_count > 0 then
        -- Sort the new words
        table.sort(new_words)

        -- Append the sorted new_words to words
        for _, word in ipairs(new_words) do
            table.insert(words, word)
        end
    end
    return match_count
end

-- Recursive function to handle glob pattern matching
function blud.glob.recursive_glob_match(words, pattern_components, index, current_path, dir_cache)
    local match_count = 0  -- Keep track of matches

    -- Base case: if we've matched all components, add the full path to words
    if index > #pattern_components then
        table.insert(words, current_path)  -- Add the full matched path
        return 1  -- Count this as one match
    end

    local part = pattern_components[index]

    -- Handle "**" special case
    if part == "**" then
        -- "**" can match zero or more directories, so we need to try all possibilities:
        -- 1. Match zero directories: call recursively with the next pattern component
        match_count = match_count + blud.glob.recursive_glob_match(words, pattern_components, index + 1, current_path, dir_cache)

        -- 2. Match one or more directories: iterate through directories in dir_cache and recurse
        for name, entry in pairs(dir_cache) do
            if entry.is_dir then
                local subdir_cache = blud.glob.get_cached_dir(entry.name)  -- Recursively fetch the subdir cache
                local subdir_path = current_path ~= "" and (current_path .. "/" .. name) or name  -- Concatenate the full path, avoiding "./"
                match_count = match_count + blud.glob.recursive_glob_match(words, pattern_components, index, subdir_path, subdir_cache)
            end
        end
    else
        -- Normal matching for the current component (using glob_expand for wildcards)
        local matched       = {}
        local matched_count = glob_expand(matched, part, dir_cache["."])
        if matched_count == 0 then
            return 0
        end

        -- For each matched entry, continue matching the remaining pattern components
        for _, matched_entry in ipairs(matched) do
            local full_path = current_path ~= "" and (current_path .. "/" .. matched_entry) or matched_entry

            if index == #pattern_components then
                table.insert(words, full_path)
                match_count = match_count + 1
            else
                local next_dir_cache = blud.glob.get_cached_dir(full_path)
                match_count = match_count + blud.glob.recursive_glob_match(
                    words,
                    pattern_components,
                    index + 1,
                    full_path,
                    next_dir_cache
                                                                          )
            end
        end
    end

    return match_count  -- Return the number of matches found
end

-- Helper function to get or create the directory cache
function blud.glob.get_cached_dir(directory)
    local cache = blud.dir_cache[directory]
    if cache == nil then
        cache = get_dir_cache(directory)
        assert(cache)
        blud.dir_cache[directory] = cache
    end
    return cache
end




function blud.glob.path_split(path)
    local components = {}
    local is_absolute = false

    -- Handle special paths: "\\.\", "\\?\"
    if string.match(path, "^\\\\%.") or string.match(path, "^\\\\%?") then
        local first_component = string.match(path, "^(\\\\[^\\]+\\?.-\\?\\?.*)")
        if first_component then
            table.insert(components, first_component)
            path = string.sub(path, #first_component + 1)
            is_absolute = true
        end
    -- Handle UNC paths: "\\server\share"
    elseif string.match(path, "^\\\\") then
        local unc_prefix = string.match(path, "^\\\\[^\\]+\\[^\\]+")
        if unc_prefix then
            table.insert(components, unc_prefix)
            path = string.sub(path, #unc_prefix + 1)
            is_absolute = true
        end
    -- Handle Drive letter paths (e.g., "C:" or "C:\")
    else
        local drive, rest_of_path = string.match(path, "^([a-zA-Z]:)(.*)")
        if drive then
            table.insert(components, drive)
            if rest_of_path:sub(1, 1) == "\\" or rest_of_path:sub(1, 1) == "/" then
                rest_of_path = rest_of_path:sub(2)  -- Remove leading slash
            end
            path = rest_of_path
            is_absolute = true
        end
    end
    
    -- Replace backslashes with forward slashes for uniform handling
    path = string.gsub(path, "\\", "/")

    -- Split path but respect [] wildcards
    local i = 1
    local part = ""
    local inside_brackets = false
    while i <= #path do
        local char = path:sub(i, i)
        
        if char == "[" then
            inside_brackets = true
            part = part .. char  -- Keep the '[' character
        elseif char == "]" then
            inside_brackets = false
            part = part .. char  -- Keep the ']' character
        elseif char == "/" and not inside_brackets then
            table.insert(components, part)
            part = ""  -- Reset part
        else
            part = part .. char  -- Accumulate the part
        end

        i = i + 1
    end

    -- Add the final part if it's non-empty
    if part ~= "" then
        table.insert(components, part)
    end

    -- If no absolute path component was found, ensure the first component is './'
    if not is_absolute and #components > 0 and not string.match(components[1], "^[a-zA-Z]:") then
        table.insert(components, 1, ".")
    end

    return components
end

--blud.macros          = {}
-- macro scopes
blud.Scope = require("scope")


--[[
function blud.Scope:set(name, value)
    self.variables[name] = value
end

function blud.Scope:get(name)
    if self == blud.Scope then
        return nil
    end
    if not self.variables then blud.error("fail on get(#1) scope: #2 ", name, dump(self)) end
    if self.variables[name] ~= nil then
        return self.variables[name]
    elseif self.parent then
        return self.parent:get(name)
    else
        return nil
    end
end

function blud.Scope:get_text(name)
    blud.assert(self.get)
    local tokens = self:get(name)
    local result = ""
    if tokens then
        result = blud.Macro.expand_tokens(self, tokens)
    end
    return result
end


-- per-target scope
-- This handles automatic macros in its "get" function
blud.ScopeTarget         = setmetatable({}, {__index = blud.Scope})
blud.ScopeTarget.__index = blud.ScopeTarget
function blud.ScopeTarget.new(target)
    blud.assert(target)
    local scope  = blud.Scope:new(blud.scope_build)
    scope.target = target
    setmetatable(scope, blud.ScopeTarget)
    return scope
end
function blud.ScopeTarget:get(name)
    local result
    local bound_name = ""
    if name == "<" then
        local first_prereq = self.target.PREREQUISITES[1]
        if first_prereq then
            result =  first_prereq.BOUND_NAME
        end
    elseif name == "^" then
        result = {}
        local seen = {}
        for _, prereq in ipairs(self.target.PREREQUISITES) do
            local bound_name = prereq.BOUND_NAME
            if not seen[bound_name] then
                seen[bound_name] = true
                table.insert(result, prereq.BOUND_NAME)
                table.insert(result,  " " )
            end
        end
        result = table.concat(result)
    elseif name == "@" then
        result = self.target.BOUND_NAME
    else
        result = self.variables[name]
        if result == nil and self.parent then
            result = self.parent:get(name)
        end
    end
    return result
end

blud.scope_base        = blud.Scope:new()
blud.scope_environment = blud.Scope:new(blud.scope_base)
blud.scope_bludfile    = blud.Scope:new(blud.scope_environment)
blud.scope_commandline = blud.Scope:new(blud.scope_bludfile)
blud.scope_build       = blud.Scope:new(blud.scope_commandline)

function blud.scope_environment:get(name)
    local value = os.getenv(name)
    if value ~= nil then
        return { value }
    end
    return self.parent:get(name)
end

-- macro class
blud.Macro = {}
blud.Macro.__index = blud.Macro
function blud.Macro:new(body)
    assert(type(body) == "string" or type(body) == "table")
    local instance = {
        body      = body
    }
    setmetatable(instance, blud.Macro)
    return instance
end
--]]


-- macro_call is an unexpanded macro call, where [1] == macro name, [2] == arg#1, etc.
-- macro_actual is the expanded macro call we are inside of, if any, needed for $(1), $(2), etc.
function blud.Macro.expand_call(scope, macro_call, stack)
    stack = stack or {}
    -- expand macro_call to get all its actual parameters (including name)
    local new_actual = {}
    for _, macro_arg in ipairs(macro_call) do
        table.insert(new_actual, blud.Macro.expand_tokens(scope, macro_arg, stack))
    end
    local result
    local name_string = new_actual[1]
    for i = 1, #stack do
        if stack[i] == name_string then
            -- util.print("recursive macro call of: %s", name_string)
            error("die")
        end
    end
    table.insert(stack, name_string)
    local macro_body  = scope:get(name_string) or ""
    if type(macro_body) == "string" then -- if macro is simple string
        result = { macro_body }
    elseif type(macro_body) == "table" then
        local param_scope = blud.Scope:new_param_scope(scope, new_actual)
assert(type(macro_body) ~= "string")
        result = { blud.Macro.expand_tokens(param_scope, macro_body, stack) }
    else
        blud.error("Can't happen.")
    end
    table.remove(stack)
    return result
end

function blud.Macro.expand_tokens(scope, tokens,     stack)
    if type(tokens) == "string" then
        return tokens
    end
    -- we internally keep a stack to detect macro recursion
    local top_level = false
    if stack == nil then
        stack       = {}
        top_level   = true
    end

    local result = {}
    for _, token in ipairs(tokens) do
        if type(token) == "string" then  -- simple string, yay!
            table.insert(result, token)
        elseif type(token) == "table" then -- macro call, PITA
            local call_result_tokens = blud.Macro.expand_call(scope, token,  stack)
            blud.array_append(result, call_result_tokens)
        else
            error("Illegal token in token array: " .. dump(token))
        end
    end
    return table.concat(result)
end

function blud.Macro.expand_text(scope, text,      stack)
    local tokens = blud.macro_tokens_from_text(text)
    return blud.Macro.expand_tokens(scope, tokens)
end


function blud.Macro:assign_early(scope, new_body)
    if type(new_body) == "table" then -- if we are being given macro tokens
        new_body = self.expand(scope, new_body)  -- expand into string
    end
    assert(type(new_body) == "string")
    self.body = new_body
end

-- note that caller has already handled any self references
function blud.Macro:assign_late(new_body)
    if type(new_body) == "table" then -- if we are being given macro tokens
        self.body = new_body
    elseif type(new_body) == "string" then
        self.body = { new_body }      -- store string as array of macro tokens
    else
        error("assign_late was passed a " .. type(new_body) .. "instead of a string or table")
    end
end

-- append to an existing macro of either type
-- caller has already handled any self references
function blud.Macro:append(scope, more_body)
    if type(self.body) == "table" then  -- if I am a late-binding macro
        if type(new_body) == "string" then
            more_body = { more_body }  -- turn string into array of macro tokens
        else
            assert(type(more_body) == "table")
        end
        for _, token in ipairs(more_body) do
            table.insert(self.body, token)
        end
    elseif type(self.body) == "string" then -- else if I am an early-binding macro
        if type(more_body) == "table" then
            more_body = self.expand(scope, more_body)
        end
    else
        error("Macro:append was passed a " .. type(more_body) .. "instead of a string or table")
    end
end


blud.macro_simple_name_match = function(token, name)
    if token and type(token) == "table" and token.macro == true then
        -- it's a macro call stack, and [1] will be the tokens making up the name
        local name_tokens = token[1]
        -- we detect FOO = $(FOO) + 1, not FOO = $(F$(OO)) + 1
        if #name_tokens == 1 then
            return name_tokens[1][1] == name
        end
    end
    return false
end

-- macro_extract_call:
--     extract macro invocation from text at pos. No error return,
-- if it's not looking like a macro, we just skip the '$'
-- returns a symbolic macro reference, including any actual parameters
blud.macro_extract_call = function(text, pos, self_reference)
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
        pos = pos + 1 -- skip over macro name
    else    -- else looks like paren-style macro invocation
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
    if self_reference then
        arg_stack = self_reference(arg_stack)
    end
    return arg_stack, pos
end

blud.macro_tokens_from_string = function(name, str)
    return {name=name, [1] = str}
end

-- macro_tokens_from_text: compile a macro body into a table
--    A macro body is stored as a table. Each entry in the table
-- is either a substring that contains no macro invocations,
-- or else a table that describes a macro call.
blud.macro_tokens_from_text = function(text, stop_chars, pos, self_reference)
    stop_chars        = stop_chars or "%$"
    stop_chars        = "(" .. stop_chars .. ")"
    pos               = pos or 1
    local result      = {}
    blud.assert(text)
    local len         = #text

    while pos <= len do
        local stop_pos,_,stop_char = text:find(stop_chars, pos)
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
            local macro_call, new_pos = blud.macro_extract_call(text, stop_pos, self_reference)
--            table.insert(result, macro_call)
            blud.array_append(result, macro_call)
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

    return result, pos
end

blud.match_macro_assign = function(line)
    local operators = {
        ["="]   = true,
        [":="]  = true,
        ["+="]  = true,
    }
    local pattern = "^" .. blud.macro_name_pattern .. "%s*([=+:]+)%s*(.*)$"
    local macro_name, operator, remainder = line:match(pattern)
    if macro_name and operator then
        if operators[operator] == true then
            return macro_name, operator, remainder
        end
    end
    return nil
end

blud.build_init = function()
    local OWD = {[1] = ".", ["name"] = "OWD"}
    blud.Scope.base:set("OWD", OWD)
    if blud.BUILD_DEFAULT then
        local mkdir_result = os_mkdir(blud.BUILD_DEFAULT.NAME)
        if mkdir_result == 2 then
            error("could not create build directory: " .. blud.BUILD_DEFAULT.NAME)
        end
        OWD = { [1] = blud.BUILD_DEFAULT.NAME, ["name"] = "OWD" }
        blud.Scope.bludfile:set("OWD", OWD)
    end
end

-- blud.lines: return an iterator that returns one line of the string at a time
blud.lines = function(str)
    local pos = 1
    return function()
        if pos > #str then return nil end
        local nl = str:find("\n", pos, true)
        local line
        if nl then
            line = str:sub(pos, nl - 1)
            pos = nl + 1
        else
            line = str:sub(pos)
            pos = #str + 1
        end
        if line:sub(-1) == "\r" then
            line = line:sub(1, -2)
        end
        return line
    end
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

    local tokens = blud.macro_tokens_from_text(text)
    local result = {}
    for _, token in ipairs(tokens) do
        if type(token) == "string" then
            table.insert(result, token)
        elseif type(token) == "table" then
            assert(token.macro)
            table.insert(result, expand_macro_call(scope, stack))
        end
    end
    return table.concat(result)

--[===[
    local result = {}
    local pos    = 1
    local len    = #text
    stack = stack or {}

    while pos <= len do
        local dollar_pos = text:find("%$", pos)

        if dollar_pos then -- if we found another macro invocation
            -- first append text up to macro invocation
            table.insert(result, text:sub(pos, dollar_pos - 1)) 
            local new_text, newPos = blud.macro_expand_from_text(scope, text, dollar_pos, stack)
            table.insert(result, new_text)
            pos = newPos
        else
            -- No more "$" found, accumulate the remaining text
            table.insert(result, text:sub(pos, len))
            break
        end
    end

    return table.concat(result)
]===]
end

blud.is_positive_integer = function(n)
    if type(n) == "string" then
        n = tonumber(n)
    end
    return type(n) == "number" and n >= 0 and n%1 == 0
end

-- $(1) is an arg reference; $(-5) is not; $(FOO) is not.
-- $($(FOO)) is not an arg reference, 
blud.macro_is_arg_reference = function(macro_token)
    local result = -1 -- -1 means "no", other positive integers indicate arg #
    if type(macro_token) == "table" and macro_token.macro then
        local macro_name_tokens = macro_token[1]
        if #macro_name_tokens == 1 then
            local macro_name_token = macro_name_tokens[1]
            if blud.is_positive_integer(macro_name_token) then
                result = tonumber(macro_name_token)+1
            end
        end
    end
    return result
end

-- given:
--     FOO = $(FOO a,b) xxx
-- we must expand the self-reference using the body of FOO
-- only arguments will be expanded (so usually nothing gets expanded at all!)
blud.macro_expand_self_reference = function(macro_call, macro_tokens)
    local result = {}
    -- copy tokens, looking for $(N args) macro invocations
    for _, element in ipairs(macro_tokens) do
        local arg_number = blud.macro_is_arg_reference(element)
        if arg_number > 0 then
            error("can't handle self-ref args yet!")
        else
            table.insert(result, element)
        end
    end
    return result
end


do
    local ref_count = 0  -- counter for making unique names
    -- traverse parts, change any macro call named 'old_name' to 'new_name'
    local function rewrite_self_references(parts, old_name, new_name)
        local result = false   -- assume we won't find any
        for i = 1, #parts do
            local part = parts[i]
            if part.macro then
                local arg = part[1]
                if #arg == 1 and arg[1] == old_name then
                    result = true   -- let caller know we found at least one
                    arg[1] = { new_name }
                end
                
            else
            end
            
        end
        return result
    end
    blud.macro_assign_parts = function(scope, macro_name, operator, parts)
        local existing_parts = scope:get(macro_name)
        if parts then
            parts = util.deep_copy(parts)
        else
            parts = {}
        end
        if operator == "?=" then -- if set-if-not-set operator
            if existing_parts ~= nil then return end
            operator = "="   -- if not set, then it's an ordinary assignment
        end
        if operator == "=" then
            ref_count = ref_count + 1
            local new_name = string.format("%s %3d", macro_name, ref_count)
            if rewrite_self_references(parts, macro_name, new_name) then
                scope:set(new_name, existing_parts)
            end
        elseif operator == "+=" then
            local new_parts = util.deep_copy(existing_parts or {})
            if #new_parts > 0 and #parts > 0 then
                table.insert(new_parts, " ")
            end
            util.array_append(new_parts, parts)
            parts = new_parts
        else
            error("Unknown assignment operator '" .. operator .. "':")
            assert(false)
        end
        scope:set(macro_name, parts)
    end
end

--[[
-- macro_assign: assign a body to a macro
-- the value of a macro will always be a function which returns either
-- a string, or the macro-expanded value of a string.
blud.macro_assign = function(line, scope, macro)
    local referenced_macro = scope:get(macro.name)
    local self_reference = function(macro_call)
        print("self-reference wrapper on macro ", macro.name, dump(macro_call))
        local macro_name_tokens = macro_call[1]
        if #macro_name_tokens == 1 and macro_name_tokens[1] == macro.name then
            return blud.macro_expand_self_reference(macro_call, referenced_macro)
        else
            return macro_call
        end
    end
    local macro_body = blud.macro_tokens_from_text(line, nil, macro.body_pos, self_reference);
    local result   = line
    local operator = macro.operator
    
    if operator == "=" then
        -- do nothing
    elseif operator == ":=" then
        macro_body = blud.Macro.expand_text(scope, input)
    else
        error("Unknown assignment operator '" .. macro.operator .. "':" .. line)
        assert(false)
    end
    scope:set(macro.name, macro_body)
    return result
end

--]]


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
    local assign_pattern = "^" .. blud.macro_name_pattern .. "%s*([=+:])()"
    local name, operator, body_pos = line:match(assign_pattern)
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


function blud.phase3:looks_like_dependency_line(text)
    -- ??? make better!
    local match = text:match("^[^%s].*:")
    return match ~= nil
end

function blud.phase3:looks_like_empty_line(text)
    -- handle comments
    local match = string.find(text, "^%s*$")
    return match ~= nil
end

function blud.phase3:looks_like_action_line(text)
    -- handle comments
    local match = string.find(text, "^%s+")
    return match ~= nil
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
    return tokens
end

-- variables have been expanded, we have line of the form <targets> <colon_operator> <prerequisites>
function blud.phase3:compile_rule(dependency_line, action)
-- print("********************* compile_rule")
    local tokens = blud.phase3:tokenize(dependency_line)
    local targets = {}
    local prerequisites = {}
    local token_pos = 1
    local token     = ""
    while token_pos <= #tokens do   -- for each token on dependency line
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


function is_pattern(word)
    if word:sub(1,2) == "[[" then
        return false
    elseif word:find("[%[?*]") == nil then
        return false
    else
        return true
    end
end

--[=[
-- only handle '*', only handle current directory
-- Take glob pattern and add to table all the matching names in current directory
function expand_pattern(words, pattern)
    local path = path_split(pattern)


    local dir = "."
    local dir_cache = blud.dir_cache[dir]
    if dir_cache == nil then
        dir_cache = get_dir_cache(dir)
        assert(dir_cache)
        blud.dir_cache[dir] = dir_cache
    end
    error("dir_cache is " .. dump(dir_cache))
    local names = dir_cache["."]
    local word_count = #words
    glob_expand(words, pattern, names)
    -- if pattern matched nothing, leave it as literal target
    if word_count == #words then
        table.insert(words, pattern)  -- no match, so treat pattern as literal
    end
end
--]=]

function blud.phase3:parse()
    -- print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!phase2_text!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
    -- print(blud.phase2_text)
    -- print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!END phase2_text!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
    local get_line          = blud.lines(blud.phase2_text)
    local action_legal_here = false
    local line              = get_line()
    self.text = {}
    while line do
        assert(line ~= nil)
        local macro = self:looks_like_macro_assign(line)
        if macro then
            line = blud.macro_assign(line, blud.Scope.bludfile, macro)
            table.insert(self.text, line .. "\n")
            line = get_line()
        elseif self:looks_like_dependency_line(line) then

-- print("unexpanded = ", dump(line))
            local dependency_line = blud.Macro.expand_text(blud.Scope.bludfile, line)
-- print("expanded = ", dump(dependency_line))
            local parsed = tokenize_dependency_line(dependency_line)
-- print("parsed = ", dump(parsed))
            local expanded = {}
            for _, word in ipairs(parsed) do
                if is_pattern(word) then
                    blud.glob.expand_pattern(expanded, word)
                else
                    table.insert(expanded, word)
                end
            end
-- print("expanded = ", dump(expanded))
-- ???
            dependency_line = table.concat(expanded, " ")
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
        else
            error("wtf: '" .. line .. "'")
        end
    end
    -- print(table.concat(self.text))
end


--[=[
blud.phase3       = function ()
    -- print(blud.phase2_text)
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

blud.super_atom = require("atom")

blud.get_fs_timestamp = function (filepath)
    local command = string.format("stat -c %%Y '%s' 2>/dev/null", filepath)
    local pipe = io.popen(command, "r")
    local output = pipe:read("*a")
    pipe:close()

    -- Convert the timestamp to a number
    local timestamp = tonumber(output)
    if not timestamp then
--        print("Failed to get timestamp for file: " .. filepath)
        timestamp = 0
    end
    return timestamp
end

blud.operator_super = require("operator")

-- we have a dependency rule, possibly with multiple targets
-- for each target create the rule
blud.add_rules = function(colon_operator, targets, prerequisites, action)

-- print("blud.add_rules targets = " .. dump(targets) .. tostring(colon_operator) .. dump(prerequisites))

    local prereq_atoms = {}
    for _, prereq_name in ipairs(prerequisites) do
        local prerequisite = blud.get_or_create_target(prereq_name)
        table.insert(prereq_atoms, prerequisite)
    end
    for _, target_name in ipairs(targets) do
        local target = blud.get_or_create_target(target_name)
        if not target.IMPLICIT and colon_operator ~= ':BUILD:' then
            if blud.default_target == nil then
                blud.default_target = target
            end
        end
        local operator = blud.operators[colon_operator]
        if operator == nil then
            errorf("'#1': undefined operator.", colon_operator)
        end
        action = action or blud.default_action
        -- util.print("    calling operator %s with prereqs %s", colon_operator, util.dump(prereq_atoms))
        operator(colon_operator, target, prereq_atoms, action)
--        target.ADD_RULE(target, prereq_atoms, action)
    end
end


--[=[
blud.build = function(target, parent_atom)
    print("[[[[[[[[[build " .. target.NAME .. "]]]]]]]]")
    blud.global.BIND(target)
    target.PARENT = parent_atom
    target:BUILD_PREREQUISITES()
    return target:BUILD()
end
--]=]

blud.get_or_create_target = function(target_name)
    local target = blud.TARGETS[target_name]
    if target == nil then
        target = blud.new_atom(target_name)
        blud.TARGETS[target_name] = target
        blud.PREREQUISITES = {}
        target.SCOPE = blud.Scope:new_target_scope(target)
        if target_name:find("%%") then
            target.IMPLICIT = true
        end
    end
    return target
end

-- build
--[[
blud.run_build = function(primary_target)
    error("run_build")
    local targets = {}
--    print("blud " .. primary_target)
    table.insert(targets, blud.get_or_create_target(primary_target))
--    print("before for: Type of blud.build:", type(blud.build)) 
    for _, target in ipairs(targets) do
        target:BUILD()
    end
end
--]]

--[[UNIT_TESTS
do
print("runtime.lua unit tests")

blud.macro_assign_parts(blud.scope_bludfile, "TEST", "=",
                        { [1] = "gcc" ,[2] = { [1] = { [1] = "EMPTY",} ,["macro"] = true,} ,} )
local value = blud.macro("TEST")
print("TEST = '" .. value .. "'")
assert(value == "gcc")
blud.macro_assign_parts(blud.scope_bludfile, "EMPTY", "=", { [1] = "NOTEMPTY" })
local value = blud.macro("TEST")
print("TEST = '" .. value .. "'")
assert(value == "gccNOTEMPTY")

end
--]]
