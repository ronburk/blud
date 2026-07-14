-- Atom defaults and atom creation.
local dump = util.dump

-- define super atom (a metatable), which contains defaults for all atoms
local super_atom = {
    NAME = "",
    set_variable = function(target, macro)
        assert(target)
        assert(macro)
        assert(macro.name)
        assert(macro.operator)
        assert(macro.macro_text ~= nil)

        if not target.SCOPE then
            target.SCOPE = blud.ScopeTarget:new(target)
        end

        local parts = blud.macro_tokens_from_text(macro.macro_text)
        blud.macro_assign_parts(target.SCOPE, macro.name, macro.operator, parts)
    end,
    get_action = function(target)
        local action
        if target.RULE then
            action = target.RULE.action
        end
        return action
    end
    ,
    ADD_PREREQUISITE = function(target, prerequisite)
        -- util.print("ADD_PREREQUISITE target=%s", util.dump(target))
        -- print("ADD_PREREQUISITE(" .. target.NAME .. ", " .. util.dump(prerequisite) .. ")")
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
        prerequisite.USED_AS_PREREQUISITE = true
    end,
    ADD_ACTION = function(target, action)
        assert(target.RULE)

        if target.RULE.action then
            errorf("Target #1 already has an action (#2), so can't give it (#3)",
                   target.NAME, target.RULE.action, action)
        else
            target.RULE.action = action
        end
    end,
--[[
    ADD_RULE = function(target_atom, prerequisites, action)
        print(">>>super_atom ADD_RULE target = " .. dump(target_atom) .. ": " .. dump(prerequisites))
        if action then
            target_atom:ADD_ACTION(action)
        end
        target_atom.HAS_RULE = true
        if prerequisites ~= nil then
            for _, prerequisite in ipairs(prerequisites) do
                util.print("    target_atom.NAME = %s", target_atom.NAME)
                target_atom.ADD_PREREQUISITE(target_atom, prerequisite)
            end
        end
--        print("<<<super_atom ADD_RULE target = " .. dump(target_atom) .. ": " .. dump(prerequisites))
    end,
--]]
    -- implement the "::" operator
    SOURCE_RULE = function(target, prerequisites, action)
        -- print("super_atom SOURCE_RULE target = " .. dump(target) .. ": " .. dump(prerequisites))
        local new_prereqs = {}
        local link_macro  = "LINK.o"

        for _, prerequisite in ipairs(prerequisites or {}) do
            -- util.print("_,prerequisite = %s,%s", _, prerequisite)
            local rule, file_stem, dir_stem = blud.implicit.find_reverse(prerequisite)
            if rule == nil then
                error("no reverse rule for " .. prerequisite)
            end
--            if prerequisite.TYPE == ".cpp" then
--                link_macro = "LINK.cxx.o"
--            end
            local output_name = blud.implicit.expand(rule.target, file_stem, dir_stem)
            local output = blud.get_or_create_target(output_name)

            -- Materialize the implicit rule:
            --     output : prerequisite
            --         rule.action
            --
            -- This is intentionally OK if the same exact rule is added twice,
            -- but ADD_RULE may still complain if the target already has a
            -- different action.
            output:ADD_RULE({ prerequisite }, rule.action)

            table.insert(new_prereqs, output)
        end

        if action == nil or action == ""  or action == blud.default_action then
            action = function(scope)
                local command_tokens = {
                    ["macro"] = true, [1] = {["type"]="text", ["text"]= link_macro}
                }
                local command = blud.Macro.expand_tokens(scope, command_tokens)
            end
            action = function(scope, status)
                status = blud.execute(scope, scope:get_text(link_macro))
                end
--            action = "$(" .. link_macro .. ")"
        end

        target:ADD_RULE(new_prereqs, action)
    end,

    APPLY_SPECIAL = function(atom, prerequisites)
        -- print("APPLY_SPECIAL " .. dump(atom))
        for _, prerequisite in ipairs(prerequisites) do
            
        end
    end,
    BIND_SWD = function(atom)
--        util.print("BIND_SWD(%s)", util.dump(atom.NAME))
        local SWD = atom.SCOPE:get_text("SWD")
        if SWD ~= "" then
            atom.BOUND_NAME = SWD .. "/" .. atom.NAME
        else
            atom.BOUND_NAME = atom.NAME
        end
        return atom
    end,
    -- BIND: associate an atom with an actual filename
    BIND  = function(atom)
        local rule = atom.RULE
        if rule then
            return rule.operator:BIND(atom)
        else
            return atom.BIND_SWD(atom)
        end
    end,
    get_timestamp = function(atom)
        assert(atom.BOUND_NAME)

        if atom.SCOPE:get_boolean(".ASSUME_NEW") then
            atom.TIMESTAMP = blud.current_time
        elseif atom.TIMESTAMP == nil then
            atom.TIMESTAMP = blud.get_fs_timestamp(atom.BOUND_NAME)
        end

        return atom.TIMESTAMP
    end,
-- prepare prerequisites for this atom to be built
-- default is to let operator do the work
    PREPARE_PREREQUISITES = function(atom)
        local rule = atom.RULE
        if rule then
            rule.operator:PREPARE_PREREQUISITES(atom)
        end
    end,
    BUILD_PREREQUISITES = function(atom)
        return atom.RULE.operator:BUILD_PREREQUISITES(atom)
    end,
    BUILD = function(target_atom)
        if target_atom.PARENT then
            target_atom.SCOPE.parent = target_atom.PARENT.SCOPE
        end

        if not target_atom.RULE then
            -- must try implicit rules now
            local implicit_rule, match, prereq_words = blud.implicit.find_forward(target_atom.NAME)
--            util.print("IMPLICIT %s | %s | %s", util.dump(implicit_rule), util.dump(match), util.dump(prereq_words))
            if implicit_rule then
                blud.operators[":"]:ADD_RULE(target_atom, prereq_words, implicit_rule.action)
            end
        end

        if target_atom.RULE then
            return target_atom.RULE.operator:BUILD(target_atom)
        end

        target_atom:BIND()
        local timestamp = target_atom:get_timestamp()
        if timestamp == 0 then
            error("Don't know how to build: " .. target_atom.NAME)
        end
        return timestamp
    end,
    BUILD_PREREQUISITES = function(atom)
        if atom.RULE and atom.RULE.prereq_words then
            -- util.print("RULE.prereq_words = %s", util.dump(atom.RULE.prereq_words))
            local prereq_names = glob_words(atom.RULE.prereq_words)
            -- util.print("names=%s", util.dump(prereq_names))
            atom.PREREQUISITES = atomize_words(prereq_names)
        end
        local prerequisites = atom.PREREQUISITES;
--        print("prereqs: " .. dump(prerequisites))
        local newest_time = 0
        if prerequisites and #prerequisites > 0 then
            -- util.print("%d BUILD_PREREQUISITES(%s)", #prerequisites, blud.dump_atom(atom))
            for _, prereq_name in ipairs(prerequisites) do
                prerequisite = atom.BIND(prereq_name)
                prerequisite.PARENT = atom
                local this_time = prerequisite.BUILD(prerequisite)
                if this_time > newest_time then
                    newest_time = this_time
                end
            end
        end
--        print("newest time is ", newest_time)
        return newest_time
    end,
    DO_ACTION = function(target_atom)
        local action
        if target_atom.RULE and target_atom.RULE.action then
            action = target_atom.RULE.action
        end
        assert(action)

        local exit_code
        -- print("DO_ACTION in super atom for " .. target_atom.NAME)
        exit_code = action(target_atom.SCOPE)

        if exit_code and exit_code ~= 0 then
            error("command failed[" .. exit_code .. "]: ")
        end
        return 0
    end,

}

-- Set up atom inheritance: atom -> super_atom -> global.
blud.global = {
}
setmetatable(super_atom, blud.global)
blud.global.__index      = blud.global
super_atom.__index  = super_atom

do
    local suffix_map = {
        [".obj"] = ".o",
        [".lib"] = ".a",
        [".C"]   = ".cpp",
        [".cc"]  = ".cpp",
        [".cxx"] = ".cpp",
        [".c++"] = ".cpp",
    }
    blud.new_atom = function(atom_name)
        local atom = {
            NAME          = atom_name,
        -- atom must always have a prerequisite list, even if it is empty
        -- this guarantees prerequisites are not inherited
            PREREQUISITES = {},
            SUFFIX        = atom_name:match("^.+(%..+)$"),
        }
        atom.SCOPE        = blud.Scope:new_target_scope(atom)
        atom.TYPE         = suffix_map[atom.SUFFIX] or atom.SUFFIX
        return setmetatable(atom, super_atom)
    end
end


blud.is_special_atom = function(atom)
    return string.sub(atom.NAME, 1, 1) == "."
end

blud.set_callback = function(target, hook_name, callback_func)
-- print("set_callback(" .. target.NAME .. ", " .. hook_name .. ")")
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
    setmetatable(atom, super_atom)
end

return super_atom
