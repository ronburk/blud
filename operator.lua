local debugger = require("debugger")

local M= {} -- super class for all operators
M.__index = M  -- search super class for missing fields
M.operator_new   = function(t)
    assert(type(t) == 'table')
    return setmetatable(t, M)
end

    -- BIND: associate an atom with an actual filename
function M:BIND(atom)
    if not atom.SCOPE then atom.SCOPE = blud.ScopeTarget:new(atom) end
    local action = atom:get_action()
    if action then
        local OWD = atom.SCOPE:get_text("OWD")
        if OWD ~= "" then
            atom.BOUND_NAME = OWD .. "/" .. atom.NAME
        end
    else
        --util.printf("%s had NO ACTION\n", atom.NAME)
        local SWD = atom.SCOPE:get_text("SWD")
        if SWD ~= "" then
            atom.BOUND_NAME = SWD .. "/" .. atom.NAME
        else
            atom.BOUND_NAME = atom.NAME
        end
    end
    return atom
end

function M:BUILD(target_atom)
        -- util.print("BUILD('%s') prereq=%s", blud.dump_atom(target_atom), util.dump(target_atom.PREREQUISITES))
        
        -- if target_atom.PARENT then print("PARENT('" .. blud.dump_atom(target_atom.PARENT) .. "')") end
        if target_atom.BUILDING == true then
            error("circular dependency on " .. target_atom.NAME)
        end
        target_atom.BUILDING   = true
        if not target_atom.RULE then
            -- must try implicit rules now
            local implicit_rule, match, prereq_words = blud.implicit.find_forward(target_atom.NAME)
            -- util.print("IMPLICIT %s | %s | %s", util.dump(implicit_rule), util.dump(match), util.dump(prereq_words))
            if implicit_rule then
                blud.operators[":"]:ADD_RULE(target_atom, prereq_words, implicit_rule.action)
            end
        end
        target_atom:BIND()
        local timestamp = blud.get_fs_timestamp(target_atom.BOUND_NAME)
        target_atom.TIMESTAMP = timestamp
        if not target_atom.RULE and timestamp == 0 then
                error("Don't know how to build: " .. target_atom.NAME)            
        end
        
        target_atom:PREPARE_PREREQUISITES()
        local newest_prerequisite = target_atom.BUILD_PREREQUISITES(target_atom)
        -- print("timestamp for '" .. target_atom.BOUND_NAME .. "' is " .. timestamp)
        -- print("    versus ", newest_prerequisite)
        if newest_prerequisite > timestamp then
            local rule = target_atom.RULE
            if rule and rule.action then
                target_atom:DO_ACTION()
                timestamp = blud.current_time
            elseif timestamp == 0 and not target_atom.RULE then
                error("Don't know how to build: " .. target_atom.NAME);
            end
        end
        target_atom.TIMESTAMP = timestamp
        target_atom.BUILDING = false
        return timestamp
    end

-- prepare prerequisites for this atom to be built
function M:PREPARE_PREREQUISITES(atom)
end

function M:EVAL_RULE(left_tokens, right_tokens, action)
    -- util.print("operation_super:EVAL_RULE(%s, %s, action)", util.dump(left_tokens), util.dump(right_tokens))
--    local target_words       = self:GLOB_TARGET_WORDS(left_tokens)
--    local prerequisite_words = self:GLOB_PREREQUISITE_WORDS(right_tokens)
--    local target_atoms       = self:ATOMIZE_TARGET_WORDS(target_words)
--    local prerequisite_atoms = self:ATOMIZE_PREREQUISITE_WORDS(prerequisite_words)
    self:ADD_RULES(left_tokens, right_tokens, action)
--    self:ADD_RULES(target_atoms, prerequisite_atoms, action)
--[[
    if not blud.primary_targets and #target_atoms > 0 then
        util.print("    -> call self(%s):SET_PRIMARY_TARGETS(%s)",
                   util.dump(self),
                   util.dump(target_atoms))
        blud.primary_targets = self:SET_PRIMARY_TARGETS(target_atoms)
    end
--]]
end
function M:GLOB_TARGET_WORDS(words)
    return glob_words(words)
end
function M:GLOB_PREREQUISITE_WORDS(words)
    return glob_words(words)
end
function atomize_words(t)
    local result = {}
    for i, v in ipairs(t) do
        result[i] = blud.get_or_create_target(v)
    end
    return result
end
function M:ATOMIZE_TARGET_WORDS(target_words)
    return atomize_words(target_words)
end
function M:ATOMIZE_PREREQUISITE_WORDS(prerequisite_words)
    return atomize_words(prerequisite_words)
end


-- override and return nil if your target cannot be primary build target
function M:SET_PRIMARY_TARGETS(target_atom)
    return target_atom
end

function M:GROUP_TARGETS(target_words, prereq_words, action)
    return false
end

-- tokenized, but not yet atomized
function M:ADD_RULES(target_words, prereq_words, action)
--[[
    util.print("blud.operator_super:ADD_RULES(%s,%s,action)",
          util.dump(target_words), util.dump(prereq_words))
--]]
    local targets = atomize_words(target_words)
    local group   = self:GROUP_TARGETS(target_words, prereq_words, action)
    
    for i=1, #targets do
        local target_atom = targets[i]
        if not blud.default_target then
            local default_target = self:SET_PRIMARY_TARGETS(target_atom)
            if default_target then
                blud.default_target = default_target
            end
        end
        if not group then -- multiple targets synonym for multiple rules
            self:ADD_RULE(target_atom, prereq_words, action)
        end
    end
    if group then
        self:ADD_RULE(targets, prereq_words, action)
    end
end

local function words_dump(words)
    local result = {}
    for i = 1, #(words or {}) do
        result[i] = tostring(words[i])
    end
    return table.concat(result, ", ")
end

local function targets_dump(targets)
    local result = {}
    for i = 1, #(targets or {}) do
        result[i] = targets[i].NAME
    end
    return table.concat(result, ", ")
end

local function rule_dump(rule)
    local lines = {}

    table.insert(lines, string.format(
        "%s %s %s",
        targets_dump(rule.targets),
        rule.operator.name or rule.operator.NAME or "?",
        words_dump(rule.prereq_words)
    ))

    if rule.action then
        table.insert(lines, "    action: " .. tostring(rule.action))
    else
        table.insert(lines, "    action: <none>")
    end

    return table.concat(lines, "\n")
end

function M:ADD_RULE(target, prereq_words, action)
   -- util.array_append(target.PREREQUISITES, prereqs)
--    util.print("blud.operator_super:ADD_RULE %s:%s", util.dump(target),util.dump(prereq_words))
    local rule = target.RULE
    if not rule then
        rule              = {}
        rule.dump         = rule_dump
        table.insert(blud.rules, rule)
        rule.targets      = { target }
        rule.prereq_words = prereq_words
        rule.operator     = self
        target.RULE       = rule
    else
        assert(not rule.action)
        util.array_append(rule.prereq_words, prereq_words)
        if rule.operator ~= self then
            error("target used with more than one operator!")
        end
    end
    rule.action       = action

    
--    local prereq_names = glob_words(prereq_words)
--    local prereq_atoms = atomize_words(prereq_names)
--    target:ADD_RULE(prereq_atoms, action)
end




--[[ killme!
blud.operators[":"] = function(colon_operator, target, prereq_atoms, action)
    if target.NAME:find("%%") then
        local rule = {target=target, prerequisites = prereq_atoms, action = action}
        table.insert(blud.implicit_rules, rule)
    else
        return target:ADD_RULE(prereq_atoms, action)
    end
end

blud.operators[":"] = function(colon_operator, target, prereq_atoms, action)
    if target.NAME:find("%%") then
        local prereq_names = {}
        for _, prereq in ipairs(prereq_atoms) do
            table.insert(prereq_names, prereq.NAME)
        end

        blud.implicit.add_rule(target.NAME, prereq_names, action)
    else
        return target:ADD_RULE(prereq_atoms, action)
    end
end

--]]

do  -- : operator
    local op = M.operator_new({})
    blud.operators[":"] = op
    function op:SET_PRIMARY_TARGETS(target_atom)
        -- util.print("[:]:SET_PRIMARY_TARGETS()=%s", util.dump(target_atom))
        return target_atom
    end

    function op:BUILD(target_atom)
        local parent_name = ''
        if target_atom.PARENT then
            parent_name = target_atom.PARENT.NAME .. ' : '
            target_atom.SCOPE.parent = target_atom.PARENT.SCOPE
        end
        -- util.print("BUILD('%s%s') prereq=%s",
        --            parent_name,
        --            blud.dump_atom(target_atom),
        --            util.dump(target_atom.PREREQUISITES))

--        -- if target_atom.PARENT then print("PARENT('" .. blud.dump_atom(target_atom.PARENT) .. "')") end
        if target_atom.BUILDING == true then
            error("circular dependency on " .. target_atom.NAME)
        end
        target_atom.BUILDING   = true
        if not target_atom.RULE then
            -- must try implicit rules now
            local implicit_rule, match, prereq_words = blud.implicit.find_forward(target_atom.NAME)
--            util.print("IMPLICIT %s | %s | %s", util.dump(implicit_rule), util.dump(match), util.dump(prereq_words))
            if implicit_rule then
                blud.operators[":"]:ADD_RULE(target_atom, prereq_words, implicit_rule.action)
            end
        end
        target_atom:PREPARE_PREREQUISITES()
        target_atom:BIND()
        local timestamp = blud.get_fs_timestamp(target_atom.BOUND_NAME)
        target_atom.TIMESTAMP = timestamp
        if not target_atom.RULE and timestamp == 0 then
                error("Don't know how to build: " .. target_atom.NAME)
        end

        local newest_prerequisite = target_atom.BUILD_PREREQUISITES(target_atom)
--        print("timestamp for '" .. target_atom.BOUND_NAME .. "' is " .. timestamp)
--        print("    versus ", newest_prerequisite)
        if newest_prerequisite > timestamp then
            local rule = target_atom.RULE
            if rule and rule.action then
                target_atom:DO_ACTION()
                timestamp = blud.current_time
            elseif timestamp == 0 and not target_atom.RULE then
                error("Don't know how to build: " .. target_atom.NAME);
            end
        end
        target_atom.TIMESTAMP = timestamp
        target_atom.BUILDING = false
        return timestamp
    end
end

do  -- %: operator
    local op = M.operator_new({})
    blud.operators["%:"] = op
    function op:SET_PRIMARY_TARGETS(target_atom)
        -- util.print("[%%:]:SET_PRIMARY_TARGETS()")
        -- implicit rules are not candidates for primary targets
        return nil
    end
    function op:ADD_RULE(target_atom, prereq_words, action)
        -- util.print("(%%:):ADD_RULE(%s, %s, action)", util.dump(target_atom), util.dump(prereq_words))
        local prereq_names = glob_words(prereq_words)
--[[
        for i = 1, #prereq_names do
            prereq_words[i] = prereq_words[i].NAME
        end
--]]
        local errmsg = blud.implicit.add_rule(target_atom.NAME, prereq_names, action)
        if errmsg then
            blud.error(errmsg)
        end
    end
end

do  -- :: operator
    local op = M.operator_new({})
    blud.operators["::"] = op

    local function prepare_prerequisites(target_atom)
        local source_rule = target_atom.RULE
        assert(source_rule)

        if source_rule.source_rule_prepared then
            return
        end

        debugger.probe({func="PREPARE_PREREQUISITES", target=target_atom})
        local prereq_words = glob_words(source_rule.prereq_words)
        local new_prereqs  = {}
        local link_macro   = "LINK.o"

        -- Each source prerequisite becomes an object prerequisite, using
        -- the reverse implicit-rule lookup to materialize rules like:
        --     foo.o : foo.c
        for _, prereq_name in ipairs(prereq_words) do
            local implicit_rule, file_stem, dir_stem =
                blud.implicit.find_reverse(prereq_name)
            if not implicit_rule then
                blud.error("no reverse rule for %s", prereq_name)
            end

            if util.match_or(prereq_name, "%.cpp$|%.cxx$|%.cc$") then
                link_macro = "LINK.cxx.o"
            end

            local output_name = blud.implicit.expand(implicit_rule.target, file_stem, dir_stem)
            local output_atom = blud.get_or_create_target(output_name)

            if output_atom.RULE then
                if output_atom.RULE.operator ~= blud.operators[":"] then
                    blud.error("target %s already has a non-':' rule", output_name)
                end
            else
                blud.operators[":"]:ADD_RULE(output_atom, { prereq_name }, implicit_rule.action)
            end
            table.insert(new_prereqs, output_atom)
        end

        target_atom.PREREQUISITES = new_prereqs

        if not source_rule.action or source_rule.action == blud.default_action then
            source_rule.action = function(scope, status)
                return blud.execute(scope, scope:get_text(link_macro))
            end
        end

        source_rule.source_rule_prepared = true
    end

    local function build_prepared_prerequisites(target_atom)
        local newest_time = 0
        local prerequisites = target_atom.PREREQUISITES or {}

        for _, prerequisite in ipairs(prerequisites) do
            prerequisite:BIND()
            prerequisite.PARENT = target_atom
            local this_time = prerequisite:BUILD()
            if this_time > newest_time then
                newest_time = this_time
            end
        end

        return newest_time
    end

    function op:BUILD(target_atom)
        local parent_name = ''
        if target_atom.PARENT then
            parent_name = target_atom.PARENT.NAME .. ' :: '
            target_atom.SCOPE.parent = target_atom.PARENT.SCOPE
        end
        -- util.print("BUILD('%s%s') prereq=%s",
        --            parent_name,
        --            blud.dump_atom(target_atom),
        --            util.dump(target_atom.PREREQUISITES))

        if target_atom.BUILDING == true then
            error("circular dependency on " .. target_atom.NAME)
        end

        target_atom.BUILDING = true
        prepare_prerequisites(target_atom)
        target_atom:BIND()

        local timestamp = blud.get_fs_timestamp(target_atom.BOUND_NAME)
        target_atom.TIMESTAMP = timestamp

        local newest_prerequisite = build_prepared_prerequisites(target_atom)
        if newest_prerequisite > timestamp then
            local rule = target_atom.RULE
            if rule and rule.action then
                target_atom:DO_ACTION()
                timestamp = blud.current_time
            elseif timestamp == 0 then
                error("Don't know how to build: " .. target_atom.NAME)
            end
        end

        target_atom.TIMESTAMP = timestamp
        target_atom.BUILDING = false
        return timestamp
    end
end

do
    local op = M.operator_new({})
    blud.operators[":TEST:"] = op

    local function relativize_test_path(suite_name, word)
        -- Relative test names are interpreted inside the suite directory.
        if word:match("^/") or word:match("^[A-Za-z]:[/\\]") then
            return word
        end
        return suite_name .. "/" .. word
    end

    local function expand_test_words(suite_name, prereq_words)
        local patterns = {}
        for _, word in ipairs(prereq_words) do
            table.insert(patterns, relativize_test_path(suite_name, word))
        end
        return glob_words(patterns)
    end

    local function test_log_name(test_name)
        return test_name .. ".log"
    end

    -- a :TEST: name cannot be a primary target
    function op:SET_PRIMARY_TARGETS(target_atom)
        return nil
    end

    function op:ADD_RULE(target, prereq_words, action)
        if not action or action == blud.default_action then
            blud.error("#1: :TEST: requires an action.", target.NAME)
        end

        if not target.RULE then
            -- Record the suite as a :TEST: target, but keep its individual
            -- test cases and actions outside the ordinary one-rule model.
            M.ADD_RULE(self, target, {}, nil)
        elseif target.RULE.operator ~= self then
            blud.error("#1: target used with more than one operator.", target.NAME)
        end

        target.TESTS = target.TESTS or {}
        target.TESTS_BY_NAME = target.TESTS_BY_NAME or {}

        local test_names = expand_test_words(target.NAME, prereq_words)
        for _, test_name in ipairs(test_names) do
            local test_atom = blud.get_or_create_target(test_name)

            if not target.TESTS_BY_NAME[test_name] then
                -- Preserve the order in which tests first enter the suite.
                target.TESTS_BY_NAME[test_name] = test_atom
                table.insert(target.TESTS, test_atom)
            end

            -- Actions are associated with test atoms, not with the suite rule.
            -- A later assertion deliberately replaces an earlier default.
            test_atom.TEST_ACTIONS = test_atom.TEST_ACTIONS or {}
            test_atom.TEST_ACTIONS[target] = action
        end
    end

    function op:PREPARE_PREREQUISITES(target)
        local rule = target.RULE
        assert(rule)

        if rule.test_rule_prepared then
            return
        end

        local tests = target.TESTS or {}
        if #tests == 0 then
            blud.error("#1: :TEST: matched no tests.", target.NAME)
        end

        local test_dir = target.SCOPE:get_text("OWD") .. "/" .. target.NAME
        if os_mkdir(test_dir) == 2 then
            error("could not create test directory: " .. test_dir)
        end

        local log_names = {}
        for _, test_atom in ipairs(tests) do
            local test_action = test_atom.TEST_ACTIONS[target]
            assert(test_action)

            local log_name = test_log_name(test_atom.NAME)
            local log_atom = blud.get_or_create_target(log_name)
            if log_atom.RULE then
                blud.error("#1: test log target already has a rule.", log_name)
            end

            local function log_action(scope)
                local log_path = scope:get_text("@")
                os.remove(log_path)

                local status = test_action(scope)
                if status and status ~= 0 then
                    return status
                end

                util.string_to_file(log_path, "success\n")
                return 0
            end

            blud.operators[":"]:ADD_RULE(
                log_atom,
                { test_atom.NAME },
                log_action
            )
            table.insert(log_names, log_name)
        end

        rule.prereq_words = log_names
        rule.test_rule_prepared = true
    end

    function op:BUILD(target)
        return M.BUILD(self, target)
    end
end


-- :BUILD: operator
do
    local op = M.operator_new({})
    blud.operators[":BUILD:"] = op

    -- a build name cannot be a primary target
    function op:SET_PRIMARY_TARGETS(target_atom)
        -- util.print("[:BUILD:]:SET_PRIMARY_TARGETS()")
        return nil
    end

    function op:ADD_RULE(target, prereqs, action)
        -- util.print("[:BUILD:]:ADD_RULE(%s, %s, action)",
        --            util.dump(target), util.dump(prereqs))

        if target.USED_AS_PREREQUISITE then
            blud.error("%s: build name was previously used as prerequisite.", target.NAME)
        end
        if not blud.default_build then
            blud.default_build = target
        end
        target.NOT_PREREQUISITE = "Build names can't be used as prerequisites."
        target.ACTION = action
        if target.SCOPE.variables.OWD == nil then
            target.SCOPE:set("OWD", {
                [1] = target.NAME,
                name = "OWD",
            })
        end
        -- Important: do not call target:ADD_RULE().
        -- A :BUILD: declaration is not a build dependency rule.
        M.ADD_RULE(self, target, {}, nil)
    end

    function op:BUILD(target)
        util.print("[:BUILD:]:BUILD(%s)", target.NAME)
        assert(target.SCOPE)
        local owd = target.SCOPE:get_text("OWD")
        local mkdir_result = os_mkdir(owd)
        if mkdir_result == 2 then
            error("could not create build directory: " .. owd)
        end
        blud.Scope.build.variables = target.SCOPE.variables
        return 0
    end
end

--[[
blud.operators[":TEST:"] = function(colon_operator, target, prereq_atoms, action)
    util.print(":TEST:[%s] operator=%s, prereqs = %s",
               target.NAME, colon_operator, util.dump(prereq_atoms))
    if not action or action == blud.default_action then
        blud.error(":TEST: target #1 requires an action", target.NAME)
    end
    
    if target.TEST then
        blud.error("Target #1 already has a :TEST: rule.", target.NAME)
    end

    if prereq_atoms ==nil or not next(prereq_atoms) then
        local entries = {}
--        blud.glob.expand_pattern(entries, target.NAME, "*")
        blud.glob.expand_pattern(entries, "./test/*")
        util.print("glob: %s", util.dump(entries))
        error("die")
    else
        for i= 1, #prereq_atoms do
            local entries = {}
            local atom = prereq_atoms[i]
            blud.glob.expand_pattern(entries, prereq_atoms[i])
            util.print("glob: %s", util.dump(entries))
        end
        error("die glob")
    end
    
    target.TEST = {
        prerequisites = prereq_atoms,
        action = action,
    }

    target.HAS_RULE = true
end

--]]
