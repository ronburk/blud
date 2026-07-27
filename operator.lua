local debugger = require("debugger")

local M= {} -- default behavior inherited by concrete operators
M.__index = M

local function target_needs_building(newest_prerequisite, timestamp)
    return blud.command_line_options.always_make or
           newest_prerequisite > timestamp
end
M.operator_new   = function(t)
    return setmetatable(t, M)
end

-- Generated targets bind under OWD; source-only targets bind under SWD.
-- The presence of an action is what distinguishes the two.
function M:BIND(atom)
    if not atom.SCOPE then atom.SCOPE = blud.ScopeTarget:new(atom) end
    assert(atom.SCOPE.target == atom,
           "target has a scope owned by another atom: " .. tostring(atom.NAME))
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

-- Default timestamp-driven build used by aggregate-like operators.
function M:BUILD(target_atom)
        -- util.print("BUILD('%s') prereq=%s", blud.dump_atom(target_atom), util.dump(target_atom.PREREQUISITES))
        
        -- if target_atom.PARENT then print("PARENT('" .. blud.dump_atom(target_atom.PARENT) .. "')") end
        if target_atom.BUILDING == true then
            error("circular dependency on " .. target_atom.NAME)
        end
        target_atom.BUILDING   = true
        if not target_atom.RULE then
            -- Resolve implicit rules lazily, when a target is actually requested.
            local implicit_rule, match, prereq_words = blud.implicit.find_forward(target_atom.NAME)
            -- util.print("IMPLICIT %s | %s | %s", util.dump(implicit_rule), util.dump(match), util.dump(prereq_words))
            if implicit_rule then
                blud.operators[":"]:ADD_RULE(target_atom, prereq_words, implicit_rule.action)
            end
        end
        target_atom:BIND()
        local timestamp = target_atom:get_timestamp()
        if not target_atom.RULE and timestamp == 0 then
                BLUD_EXIT(1000, target_atom.NAME)
        end
        
        -- Operators may materialize or rewrite prerequisites once build scope exists.
        target_atom:PREPARE_PREREQUISITES()
        local newest_prerequisite_time, newest_prerequisite =
            target_atom.BUILD_PREREQUISITES(target_atom)
        -- print("timestamp for '" .. target_atom.BOUND_NAME .. "' is " .. timestamp)
        -- print("    versus ", newest_prerequisite_time)
        local needs_building =
            target_needs_building(newest_prerequisite_time, timestamp)
        blud.why.considered(
            target_atom,
            timestamp,
            newest_prerequisite_time,
            newest_prerequisite,
            needs_building
        )
        if needs_building then
            local rule = target_atom.RULE
            if rule and rule.action then
                blud.why.action_started(target_atom)
                target_atom:DO_ACTION()
                blud.why.action_completed(target_atom)
                -- Record successful actions even when they do not create a file.
                target_atom.TIMESTAMP = blud.current_time
                timestamp = target_atom.TIMESTAMP
            elseif timestamp == 0 and not target_atom.RULE then
                BLUD_EXIT(1000, target_atom.NAME);
            end
        end
        target_atom.TIMESTAMP = timestamp
        target_atom.BUILDING = false
        return timestamp, needs_building
    end

-- Hook for operators that lazily materialize or rewrite prerequisites.
function M:PREPARE_PREREQUISITES(atom)
end

function M:EVAL_RULE(left_tokens, right_tokens, action)
    -- util.print("operation_super:EVAL_RULE(%s, %s, action)", util.dump(left_tokens), util.dump(right_tokens))
--    local target_words       = self:GLOB_TARGET_WORDS(left_tokens)
    local prerequisite_words = self:GLOB_PREREQUISITE_WORDS(right_tokens)
--    local target_atoms       = self:ATOMIZE_TARGET_WORDS(target_words)
--    local prerequisite_atoms = self:ATOMIZE_PREREQUISITE_WORDS(prerequisite_words)
    self:ADD_RULES(left_tokens, prerequisite_words, action)
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

-- Parsed target words are normally independent rules; an operator can group them.
function M:ADD_RULES(target_words, prereq_words, action)
--[[
    util.print("blud.operator_super:ADD_RULES(%s,%s,action)",
          util.dump(target_words), util.dump(prereq_words))
--]]
    local targets = atomize_words(target_words)
    local group   = self:GROUP_TARGETS(target_words, prereq_words, action)
    
    for i=1, #targets do
        local target_atom = targets[i]
        -- The first target accepted by its operator becomes the default.
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
    -- Repeated declarations accumulate prerequisites until one supplies the action.
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
        if rule.operator ~= self then
            error(
                "target used with more than one operator: " ..
                tostring(target.NAME)
            )
        end
        assert(not rule.action,
               "target already has an action: " .. tostring(target.NAME))
        util.array_append(rule.prereq_words, prereq_words)
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

do  -- Ordinary explicit dependency rules.
    local op = M.operator_new({})
    blud.operators[":"] = op
    function op:SET_PRIMARY_TARGETS(target_atom)
        -- util.print("[:]:SET_PRIMARY_TARGETS()=%s", util.dump(target_atom))
        return target_atom
    end

    function op:BUILD(target_atom)
        local parent_name = ''
        if target_atom.PARENT then
            -- Prerequisites inherit target-specific variables from their parent.
            parent_name = target_atom.PARENT.NAME .. ' : '
            target_atom.SCOPE:set_target_parent(target_atom.PARENT.SCOPE)
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
            -- Resolve implicit rules lazily, when a target is actually requested.
            local implicit_rule, match, prereq_words = blud.implicit.find_forward(target_atom.NAME)
--            util.print("IMPLICIT %s | %s | %s", util.dump(implicit_rule), util.dump(match), util.dump(prereq_words))
            if implicit_rule then
                blud.operators[":"]:ADD_RULE(target_atom, prereq_words, implicit_rule.action)
            end
        end
        target_atom:PREPARE_PREREQUISITES()
        target_atom:BIND()
        local timestamp = target_atom:get_timestamp()
        if not target_atom.RULE and timestamp == 0 then
                BLUD_EXIT(1000, target_atom.NAME)
        end

        local newest_prerequisite_time, newest_prerequisite =
            target_atom.BUILD_PREREQUISITES(target_atom)
--        print("timestamp for '" .. target_atom.BOUND_NAME .. "' is " .. timestamp)
--        print("    versus ", newest_prerequisite_time)
        local needs_building =
            target_needs_building(newest_prerequisite_time, timestamp)
        blud.why.considered(
            target_atom,
            timestamp,
            newest_prerequisite_time,
            newest_prerequisite,
            needs_building
        )
        if needs_building then
            local rule = target_atom.RULE
            if rule and rule.action then
                blud.why.action_started(target_atom)
                target_atom:DO_ACTION()
                blud.why.action_completed(target_atom)
                target_atom.TIMESTAMP = blud.current_time
                timestamp = target_atom.TIMESTAMP
            elseif timestamp == 0 and not target_atom.RULE then
                BLUD_EXIT(1000, target_atom.NAME);
            end
        end
        target_atom.TIMESTAMP = timestamp
        target_atom.BUILDING = false
        return timestamp, needs_building
    end
end

do  -- Pattern rules are registered for later implicit-rule lookup.
    local op = M.operator_new({})
    blud.operators["%:"] = op
    function op:SET_PRIMARY_TARGETS(target_atom)
        -- util.print("[%%:]:SET_PRIMARY_TARGETS()")
        -- implicit rules are not candidates for primary targets
        return nil
    end
    function op:ADD_RULE(target_atom, prereq_words, action)
        -- util.print("(%%:):ADD_RULE(%s, %s, action)", util.dump(target_atom), util.dump(prereq_words))
        assert(target_atom.NAME:find("%", 1, true),
               "pattern-rule target has no '%' wildcard: " ..
               tostring(target_atom.NAME))
        -- Pattern rules live in the implicit-rule index, not on the pattern atom.
        local errmsg = blud.implicit.add_rule(target_atom.NAME, prereq_words, action)
        if errmsg then
            blud.error(errmsg)
        end
    end
end

do  -- Source lists: compile each source through a reverse rule, then link.
    local op = M.operator_new({})
    blud.operators["::"] = op

    local function prepare_prerequisites(target_atom)
        local source_rule = target_atom.RULE
        assert(source_rule and source_rule.operator == op,
               "'::' prerequisite preparation requires a '::' rule for: " ..
               tostring(target_atom.NAME))

        -- Reverse-rule materialization remains deferred until build scope is known.
        if source_rule.source_rule_prepared then
            return
        end

        debugger.probe({func="PREPARE_PREREQUISITES", target=target_atom})
        local new_prereqs  = {}
        local link_macro   = "LINK.o"

        -- Each source prerequisite becomes an object prerequisite, using
        -- the reverse implicit-rule lookup to materialize rules like:
        --     foo.o : foo.c
        for _, prereq_name in ipairs(source_rule.prereq_words) do
            local implicit_rule, file_stem, dir_stem =
                blud.implicit.find_reverse(prereq_name)
            if not implicit_rule then
                blud.error("no reverse rule for %s", prereq_name)
            end

            -- Any C++ source selects the C++ default linker.
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

        -- An explicit action wins; otherwise use the selected link macro.
        if not source_rule.action or source_rule.action == blud.default_action then
            source_rule.action = function(scope, status)
                return blud.execute(scope, scope:get_text(link_macro))
            end
        end

        assert(source_rule.action,
               "'::' preparation produced no action for: " ..
               tostring(target_atom.NAME))
        source_rule.source_rule_prepared = true
    end

    local function build_prepared_prerequisites(target_atom)
        local source_rule = target_atom.RULE
        assert(source_rule and source_rule.source_rule_prepared,
               "attempted to build '::' prerequisites before preparing: " ..
               tostring(target_atom.NAME))
        local newest_time = 0
        local newest_prerequisite
        local prerequisites = target_atom.PREREQUISITES or {}

        -- These prerequisites are already atoms, so bypass word expansion.
        for _, prerequisite in ipairs(prerequisites) do
            prerequisite:BIND()
            prerequisite.PARENT = target_atom
            local this_time = prerequisite:BUILD()
            if this_time > newest_time then
                newest_time = this_time
                newest_prerequisite = prerequisite
            end
        end

        return newest_time, newest_prerequisite
    end

    function op:BUILD(target_atom)
        local parent_name = ''
        if target_atom.PARENT then
            parent_name = target_atom.PARENT.NAME .. ' :: '
            target_atom.SCOPE:set_target_parent(target_atom.PARENT.SCOPE)
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

        local timestamp = target_atom:get_timestamp()

        local newest_prerequisite_time, newest_prerequisite =
            build_prepared_prerequisites(target_atom)
        local needs_building =
            target_needs_building(newest_prerequisite_time, timestamp)
        blud.why.considered(
            target_atom,
            timestamp,
            newest_prerequisite_time,
            newest_prerequisite,
            needs_building
        )
        if needs_building then
            local rule = target_atom.RULE
            if rule and rule.action then
                blud.why.action_started(target_atom)
                target_atom:DO_ACTION()
                blud.why.action_completed(target_atom)
                target_atom.TIMESTAMP = blud.current_time
                timestamp = target_atom.TIMESTAMP
            elseif timestamp == 0 then
                BLUD_EXIT(1000, target_atom.NAME)
            end
        end

        target_atom.TIMESTAMP = timestamp
        target_atom.BUILDING = false
        return timestamp, needs_building
    end
end

do  -- Test suites aggregate one generated success-log target per test.
    local op = M.operator_new({})
    blud.operators[":TEST:"] = op

    local function is_absolute_path(path)
        return path:match("^/") or path:match("^[A-Za-z]:[/\\]")
    end

    local function suite_source_directory(suite_name)
        -- Relative test atoms use SWD to bind back into the suite directory.
        if is_absolute_path(suite_name) or suite_name:match("^%./") then
            return suite_name
        end
        return "./" .. suite_name
    end

    local function expand_test_words(suite_name, prereq_words)
        -- Glob relative patterns inside the suite while keeping atom names
        -- suite-relative; SWD supplies the removed prefix when they bind.
        local tests = {}
        local suite_prefix = suite_name .. "/"
        local source_directory = suite_source_directory(suite_name)

        for _, word in ipairs(prereq_words) do
            local absolute = is_absolute_path(word)
            local pattern = absolute and word or suite_prefix .. word

            for _, matched_path in ipairs(glob_words({ pattern })) do
                if absolute then
                    table.insert(tests, {
                        name = matched_path,
                    })
                else
                    assert(matched_path:sub(1, #suite_prefix) == suite_prefix,
                           "relative test glob escaped suite directory: " ..
                           tostring(matched_path))
                    table.insert(tests, {
                        name = matched_path:sub(#suite_prefix + 1),
                        source_directory = source_directory,
                    })
                end
            end
        end

        return tests
    end

    local function test_log_name(basename)
        -- Log names are relative to suite OWD and nested beside staged files.
        return basename .. "/" .. basename .. ".log"
    end

    local function test_basename(test_name)
        local name = test_name:gsub("[/\\]+$", "")
        local basename = name:match("([^/\\]+)$")
        if not basename or basename == "." or basename == ".." then
            blud.error("#1: invalid test name.", test_name)
        end
        return basename
    end

    local function stage_test(test_info, scope)
        -- Recreate the private test tree immediately before its action. Directory
        -- tests copy directly to the destination; file tests become dest/basename.
        -- Return shell status so a staging failure suppresses action and success log.
        if blud.just_print(scope) then
            return 0
        end

        local source = test_info.atom.BOUND_NAME
        assert(source,
               "test source was not bound before staging: " ..
               tostring(test_info.source_name))
        assert(test_info.destination,
               "test destination was not assigned before staging: " ..
               tostring(test_info.source_name))
        if source == test_info.destination then
            blud.error(
                "#1: test source and destination are the same.",
                source
            )
        end
        local source_type = os_path_type(source)

        -- Reuse virtual-shell commands so staging shares their path semantics.
        local commands = blud.shell.commands
        local status = commands.rm({
            "rm", "-rf", "--", test_info.destination,
        })
        if status ~= 0 then
            return status
        end

        if source_type == 2 then
            return commands.cp({
                "cp", "-r", "--", source, test_info.destination,
            })
        end

        -- Make file destinations directories so cp preserves the source basename.
        status = commands.mkdir({
            "mkdir", "-p", "--", test_info.destination,
        })
        if status ~= 0 then
            return status
        end

        return commands.cp({
            "cp", "--", source, test_info.destination,
        })
    end

    -- a :TEST: name cannot be a primary target
    function op:SET_PRIMARY_TARGETS(target_atom)
        return nil
    end

    -- Test patterns are suite-relative, so ADD_RULE expands them after the
    -- suite target is known instead of using ordinary prerequisite globbing.
    function op:EVAL_RULE(left_tokens, right_tokens, action)
        self:ADD_RULES(left_tokens, right_tokens, action)
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
        assert(not target.RULE.test_rule_prepared,
               "cannot add tests after preparing suite: " .. tostring(target.NAME))

        target.TESTS = target.TESTS or {}
        target.TESTS_BY_NAME = target.TESTS_BY_NAME or {}
        target.TESTS_BY_BASENAME = target.TESTS_BY_BASENAME or {}

        -- Overlapping patterns may repeat a name, but basenames must stay unique
        -- because both private destinations and logs are basename-derived.
        local tests = expand_test_words(target.NAME, prereq_words)
        for _, test in ipairs(tests) do
            local test_name = test.name
            local test_atom = blud.get_or_create_target(test_name)
            local basename = test_basename(test_name)

            if test.source_directory then
                -- Absolute tests bind directly; relative tests bind through suite SWD.
                local existing = test_atom.SCOPE.variables.SWD
                if existing and
                        test_atom.SCOPE:get_text("SWD") ~= test.source_directory then
                    blud.error(
                        "#1: test atom has conflicting source directories.",
                        test_name
                    )
                end
                test_atom.SCOPE:set("SWD", test.source_directory)
            end

            if not target.TESTS_BY_NAME[test_name] then
                local existing = target.TESTS_BY_BASENAME[basename]
                if existing then
                    blud.error(
                        "#1 and #2 have the same test basename.",
                        existing.source_name,
                        test_name
                    )
                end

                -- Preserve the order in which tests first enter the suite.
                local test_info = {
                    atom = test_atom,
                    source_name = test_name,
                    basename = basename,
                }
                target.TESTS_BY_NAME[test_name] = test_info
                target.TESTS_BY_BASENAME[basename] = test_info
                table.insert(target.TESTS, test_info)
            end

            -- A test atom may belong to several suites, each with its own action.
            -- Repeating it in one suite deliberately replaces that suite's action.
            test_atom.TEST_ACTIONS = test_atom.TEST_ACTIONS or {}
            test_atom.TEST_ACTIONS[target] = action
        end
    end

    function op:PREPARE_PREREQUISITES(target)
        local rule = target.RULE
        assert(rule and rule.operator == self,
               ":TEST: prerequisite preparation requires a :TEST: rule for: " ..
               tostring(target.NAME))

        -- Destinations depend on the selected :BUILD: OWD, so expand lazily.
        if rule.test_rule_prepared then
            return
        end

        local tests = target.TESTS or {}
        if #tests == 0 then
            blud.error("#1: :TEST: matched no tests.", target.NAME)
        end

        local owd = target.SCOPE:get_text("OWD")
        assert(owd ~= "",
               "test suite has an empty OWD: " .. tostring(target.NAME))
        local test_dir = owd .. "/" .. target.NAME
        if not blud.just_print(target.SCOPE) and os_mkdir(test_dir) == 2 then
            error("could not create test directory: " .. test_dir)
        end

        -- Each log is both a success stamp and an ordinary build prerequisite.
        local log_names = {}
        for _, test_info in ipairs(tests) do
            local test_atom = test_info.atom
            local test_action = test_atom.TEST_ACTIONS[target]
            assert(test_action,
                   "test has no action in suite " .. tostring(target.NAME) ..
                   ": " .. tostring(test_info.source_name))
            test_info.destination =
                test_dir .. "/" .. test_info.basename

            local log_name = test_log_name(test_info.basename)
            local log_atom = blud.get_or_create_target(log_name)
            if log_atom.RULE then
                blud.error("#1: test log target already has a rule.", log_name)
            end
            log_atom.SCOPE:set("OWD", test_dir)

            local function log_action(scope)
                assert(scope == log_atom.SCOPE,
                       "test log action received the wrong target scope: " ..
                       tostring(log_name))
                local log_path = scope:get_text("@")
                local just_print = blud.just_print(scope)
                -- A failed rerun must never leave an old success stamp behind.
                if not just_print then
                    os.remove(log_path)
                end

                local status = stage_test(test_info, scope)
                if status ~= 0 then
                    return status
                end

                status = test_action(scope)
                if status and status ~= 0 then
                    return status
                end

                if not just_print then
                    util.string_to_file(log_path, "success\n")
                end
                return 0
            end

            -- Source changes make the corresponding success stamp out of date.
            blud.operators[":"]:ADD_RULE(
                log_atom,
                { test_atom.NAME },
                log_action
            )
            table.insert(log_names, log_name)
        end

        -- The suite is now an ordinary aggregate over its success stamps.
        rule.prereq_words = log_names
        rule.test_rule_prepared = true
    end

    function op:BUILD(target)
        -- PREPARE_PREREQUISITES supplies the graph expected by generic BUILD.
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

    function op:EVAL_RULE(left_tokens, right_tokens, action)
        -- Validate the written prerequisite list before ordinary globbing can
        -- discard an unmatched pattern.
        assert(#right_tokens == 0,
               ":BUILD: prerequisites are not supported for: " ..
               table.concat(left_tokens, ", "))
        return M.EVAL_RULE(self, left_tokens, right_tokens, action)
    end

    function op:ADD_RULE(target, prereqs, action)
        -- util.print("[:BUILD:]:ADD_RULE(%s, %s, action)",
        --            util.dump(target), util.dump(prereqs))

        -- A build declaration selects an output/variable context, not a target.
        assert(#prereqs == 0,
               ":BUILD: prerequisites are not supported for: " ..
               tostring(target.NAME))
        assert(not action,
               ":BUILD: actions are not supported for: " ..
               tostring(target.NAME))
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
        assert(target.SCOPE and target.SCOPE.target == target,
               "build has no owning target scope: " .. tostring(target.NAME))
        assert(target.RULE and target.RULE.operator == self,
               "build target does not belong to the :BUILD: operator: " ..
               tostring(target.NAME))
        assert(target.SCOPE.variables.OWD,
               "build has no local OWD: " .. tostring(target.NAME))
        local owd = target.SCOPE:get_text("OWD")
        if not blud.just_print(target.SCOPE) then
            local mkdir_result = os_mkdir(owd)
            if mkdir_result == 2 then
                error("could not create build directory: " .. owd)
            end
        end
        -- Activate this context as the build-scope parent for ordinary targets.
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
