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

local dircache = require("blud.dircache")

local function dump1(o)
    if type(o) == 'table' then
        local s = '{ '
        for k,v in pairs(o) do
            if type(k) ~= 'number' then k = '"'..k..'"' end
            if v ~= "__index" then
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
    io.stderr:write(getDetailedTraceback())
    error("", 2)
end

function glob_words(input)  -- ?? must it be global???
    local output = {}

    for _, word in ipairs(input) do
        if is_pattern(word) then
            dircache.expand_pattern(output, word)
        else
            table.insert(output, word)
        end
    end

    return output
end


blud.debugger = require("blud.debugger")
if blud.command_line_options.debug == true then
    blud.debugger.probe = blud.debugger.real_probe
end
blud.Macro = require("blud.macro")
-- shell.execute() runs blud commands; only an explicit `shell` delegates.
blud.shell = require("blud.shell")

blud.rules          = {}

blud.default_action = function (scope)
    blud.execute(scope, nil)
end


blud.just_print = function(scope)
    return scope:get_boolean(".JUST_PRINT")
end


blud.silent = function(scope)
    return scope:get_boolean(".SILENT")
end


blud.execute = function(scope, text)
    assert(type(text) == "string")
    local status
    local just_print = blud.just_print(scope)
    if just_print or not blud.silent(scope) then
        print(text)
    end
    if just_print then
        status = 0
    else
        -- Preserve the action text/status contract while shell.lua
        -- enforces explicit selection of the platform shell.
        status = blud.shell.execute(text, scope)
    end

    return status
end

blud.eval_target_assign_rule = function(left_parts, macro, assigned_parts, action)
    if macro.modifier then
        blud.error(
            "The '#1' target-assignment modifier is obsolete; " ..
            "target-specific assignments apply only to the named target.",
            macro.modifier
        )
    end
    if action then
        error("Can't have action on target-specific assignment")
    end
    local left  = blud.Macro.expand_tokens(blud.Scope.build, left_parts)
    local target_names = tokenize_dependency_line(left)

    for i = 1, #target_names do
        local target = blud.get_or_create_target(target_names[i])
        blud.macro_assign_parts(
            target.SCOPE,
            macro.name,
            macro.operator,
            assigned_parts
        )
    end
end


local function tokenize_prerequisites(text)
    local separator = text:find("|", 1, true)
    if not separator then
        return tokenize_dependency_line(text), {}
    end
    if text:find("|", separator + 1, true) then
        error("more than one '|' separator in prerequisite list")
    end

    local normal = tokenize_dependency_line(text:sub(1, separator - 1))
    local order_only = tokenize_dependency_line(text:sub(separator + 1))
    return normal, order_only
end


-- eval_rule does minimal processing then goes into the operator hook system
blud.eval_rule = function(operator_name, operand_parts, action)
    local left_parts = operand_parts.targets
    local right_parts = operand_parts.prerequisites

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
                local assigned_parts = util.deep_copy(right_parts)
                assigned_parts[1] = macro.macro_text
                return blud.eval_target_assign_rule(
                    left_parts,
                    macro,
                    assigned_parts,
                    action
                )
            end
        end
    end
    local operator = blud.operators[operator_name]
    if not operator then
        blud.error("Unknown operator: #1", operator_name)
    end
    -- Dependency declarations use the selected build context. This lets one
    -- rule choose build-specific target names and prerequisites while keeping
    -- the graph concrete before the update starts.
    local left  = blud.Macro.expand_tokens(blud.Scope.build, left_parts)
    local right = blud.Macro.expand_tokens(blud.Scope.build, right_parts)
    local directory = operand_parts.directory and
        blud.Macro.expand_tokens(blud.Scope.build, operand_parts.directory)

    -- seems sketchy for some operators to tokenize differently, so do that here
    local target_names = tokenize_dependency_line(left)
    local prereq_names, order_only_prereq_names = tokenize_prerequisites(right)

    operator:EVAL_RULE({
        directory = directory,
        targets = target_names,
        prerequisites = prereq_names,
        ordered_prerequisites = order_only_prereq_names,
    }, action)
end

blud.implicit        = require("blud.implicit")
blud.error           = errorf
blud.operators       = {}
blud.build_atom      = nil
blud.default_build   = nil
blud.default_target  = nil
blud.primary_targets = nil
blud.roots           = {}

blud.array_append    = function(array, more)
    if not (type(array) == "table" and type(more) == "table") then
        blud.error("Bad call to array_append")
    end
    for _, element in ipairs(more) do
        table.insert(array, element)
    end
end

blud.Scope = require("blud.scope")

for name, value in pairs(blud.command_line_options.commandline_booleans) do
    blud.Scope.commandline:set_boolean(name, value)
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

-- macro_tokens_from_text: compile a macro body into a table
--    A macro body is stored as a table. Each entry in the table
-- is either a substring that contains no macro invocations,
-- or else a table that describes a macro call.
blud.macro_tokens_from_text = function(text, stop_chars, pos, self_reference)
    stop_chars        = stop_chars or "%$"
    stop_chars        = "(" .. stop_chars .. ")"
    pos               = pos or 1
    local result      = {}
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

blud.build_init = function()
    blud.operators[":BUILD:"]:INIT()
end

--[[

    blud.default_target is the first "buildable" target encountered in
    the bludfile, if any. If there are no command-line arguments, we just
    build that. 


--]]
local function is_build_operator(target)
    return target.RULE and
           target.RULE.operator.name == ":BUILD:"
end

local function infer_targets(default_target, targets)
    assert(default_target, "no default target to build")

    if not targets[1] then
        return { default_target }
    end

    local concrete_targets = {}

    for index, target in ipairs(targets) do
        table.insert(concrete_targets, target)
        if is_build_operator(target) and
           (not targets[index + 1] or is_build_operator(targets[index + 1])) then
            table.insert(concrete_targets, default_target)
        end
    end

    return concrete_targets
end

blud.build_targets = function(targets)
    local concrete_targets = infer_targets(blud.default_target, targets)

    if not is_build_operator(concrete_targets[1]) and blud.default_build then
        table.insert(concrete_targets, 1, blud.default_build)
    end

    blud.roots = concrete_targets

    for _, target in ipairs(blud.roots) do
        local _, needs_building = target:BUILD()
        if needs_building == false then
            print(target.NAME .. " is up to date")
        end
    end
end
blud.macro_assign_parts = function(scope, macro_name, operator, parts)
    local macro = scope:get_macro(macro_name)

    -- An undefined name has no object on which to dispatch. Start it with the
    -- ordinary parts-backed flavor; ?= then has the same effect as =.
    if macro == nil then
        macro = blud.Macro.from_parts({})
        if operator == "?=" then operator = "=" end
    end

    local replacement = macro:assign(scope, macro_name, operator, parts)
    if replacement ~= nil then
        scope:set_macro(macro_name, replacement)
    end
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

blud.why = require("blud.why")
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

require("blud.atom")

require("blud.operator")
