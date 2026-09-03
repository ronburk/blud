local AliasDir = require("blud.aliasdir")
local debugger = require("blud.debugger")
local dircache = require("blud.dircache")
local oldest_timestamp = blud.timestamp.oldest
local newest_timestamp = blud.timestamp.newest

local Operator= {} -- default behavior inherited by concrete operators
Operator.__index = Operator

local function target_needs_building(
    always_make,
    newest_prerequisite,
    timestamp
)
    return always_make or
           timestamp == oldest_timestamp or
           newest_prerequisite > timestamp
end
Operator.operator_new   = function(t)
    return setmetatable(t, Operator)
end

local function register_operator(name)
    assert(not blud.operators[name], "operator already registered: " .. name)

    local operator = Operator.operator_new({ name = name })
    blud.operators[name] = operator
    return operator
end

-- Generated targets bind under OWD; source-only targets bind under SWD.
-- The presence of an action is what distinguishes the two.
function Operator:BIND(atom)
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
function Operator:BUILD(target_atom, parent)
        -- util.print("BUILD('%s') prereq=%s", blud.dump_atom(target_atom), util.dump(target_atom.PREREQUISITES))

        if target_atom.BUILDING == true then
            error("circular dependency on " .. target_atom.NAME)
        end
        target_atom.BUILDING   = true
        -- An operator may need to finish constructing the rule before binding
        -- decides whether the target belongs under OWD or SWD.
        target_atom:PREPARE_PREREQUISITES()
        target_atom:BIND()
        local timestamp = target_atom:get_timestamp()
        if not target_atom.RULE and timestamp == oldest_timestamp then
            BLUD_EXIT(1000, target_atom.NAME)
        end

        local newest_prerequisite_time, newest_prerequisite =
            target_atom.BUILD_PREREQUISITES(target_atom)
        -- print("timestamp for '" .. target_atom.BOUND_NAME .. "' is " .. timestamp)
        -- print("    versus ", newest_prerequisite_time)
        local needs_building = target_needs_building(
            blud.command_line_options.always_make,
            newest_prerequisite_time,
            timestamp
        )
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
                target_atom:DO_ACTION(parent)
                blud.why.action_completed(target_atom)
                -- Record successful actions even when they do not create a file.
                target_atom.TIMESTAMP = newest_timestamp
                timestamp = target_atom.TIMESTAMP
            elseif timestamp == oldest_timestamp and not target_atom.RULE then
                BLUD_EXIT(1000, target_atom.NAME);
            end
        end
        target_atom.TIMESTAMP = timestamp
        target_atom.BUILDING = false
        return timestamp, needs_building
    end

-- Hook for operators that lazily materialize or rewrite prerequisites.
function Operator:PREPARE_PREREQUISITES(atom)
end

function Operator:EVAL_RULE(left_tokens, right_tokens, action)
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
function Operator:GLOB_TARGET_WORDS(words)
    return glob_words(words)
end
function Operator:GLOB_PREREQUISITE_WORDS(words)
    return glob_words(words)
end
function atomize_words(t)
    local result = {}
    for i, v in ipairs(t) do
        result[i] = blud.get_or_create_target(v)
    end
    return result
end
function Operator:ATOMIZE_TARGET_WORDS(target_words)
    return atomize_words(target_words)
end
function Operator:ATOMIZE_PREREQUISITE_WORDS(prerequisite_words)
    return atomize_words(prerequisite_words)
end


-- override and return nil if your target cannot be primary build target
function Operator:SET_PRIMARY_TARGETS(target_atom)
    return target_atom
end

function Operator:GROUP_TARGETS(target_words, prereq_words, action)
    return false
end

-- Parsed target words are normally independent rules; an operator can group them.
function Operator:ADD_RULES(
    target_words,
    prereq_words,
    action,
    order_only_prereq_words
)
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
            self:ADD_RULE(
                target_atom,
                prereq_words,
                action,
                order_only_prereq_words
            )
        end
    end
    if group then
        self:ADD_RULE(targets, prereq_words, action, order_only_prereq_words)
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
        "%s %s %s%s",
        targets_dump(rule.targets),
        rule.operator.name,
        words_dump(rule.prereq_words),
        #(rule.order_only_prereq_words or {}) > 0 and
            " | " .. words_dump(rule.order_only_prereq_words) or ""
    ))

    if rule.action then
        table.insert(lines, "    action: " .. tostring(rule.action))
    else
        table.insert(lines, "    action: <none>")
    end

    return table.concat(lines, "\n")
end

function Operator:ADD_RULE(target, prereq_words, action)
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


do  -- Ordinary explicit dependency rules.
    local Colon = register_operator(":")
    function Colon:SET_PRIMARY_TARGETS(target_atom)
        -- util.print("[:]:SET_PRIMARY_TARGETS()=%s", util.dump(target_atom))
        return target_atom
    end

    function Colon:BUILD(target_atom, parent)
        if target_atom.BUILDING == true then
            error("circular dependency on " .. target_atom.NAME)
        end
        target_atom.BUILDING   = true
        target_atom:PREPARE_PREREQUISITES()
        target_atom:BIND()
        local timestamp = target_atom:get_timestamp()
        if not target_atom.RULE and timestamp == oldest_timestamp then
                BLUD_EXIT(1000, target_atom.NAME)
        end

        local newest_prerequisite_time, newest_prerequisite =
            target_atom.BUILD_PREREQUISITES(target_atom)
--        print("timestamp for '" .. target_atom.BOUND_NAME .. "' is " .. timestamp)
--        print("    versus ", newest_prerequisite_time)
        local needs_building = target_needs_building(
            blud.command_line_options.always_make,
            newest_prerequisite_time,
            timestamp
        )
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
                target_atom:DO_ACTION(parent)
                blud.why.action_completed(target_atom)
                target_atom.TIMESTAMP = newest_timestamp
                timestamp = target_atom.TIMESTAMP
            elseif timestamp == oldest_timestamp and not target_atom.RULE then
                BLUD_EXIT(1000, target_atom.NAME);
            end
        end
        target_atom.TIMESTAMP = timestamp
        target_atom.BUILDING = false
        return timestamp, needs_building
    end
end

do  -- Pattern rules are registered for later implicit-rule lookup.
    local PercentColon = register_operator("%:")
    function PercentColon:SET_PRIMARY_TARGETS(target_atom)
        -- util.print("[%%:]:SET_PRIMARY_TARGETS()")
        -- implicit rules are not candidates for primary targets
        return nil
    end
    function PercentColon:ADD_RULE(target_atom, prereq_words, action)
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
    local DoubleColon = register_operator("::")

    local function prepare_prerequisites(target_atom)
        local source_rule = target_atom.RULE
        assert(source_rule and source_rule.operator == DoubleColon,
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
        local newest_time = oldest_timestamp
        local newest_prerequisite
        local prerequisites = target_atom.PREREQUISITES or {}

        -- These prerequisites are already atoms, so bypass word expansion.
        for _, prerequisite in ipairs(prerequisites) do
            local this_time = prerequisite:BUILD(target_atom)
            if this_time > newest_time then
                newest_time = this_time
                newest_prerequisite = prerequisite
            end
        end

        return newest_time, newest_prerequisite
    end

    function DoubleColon:BUILD(target_atom, parent)
        if target_atom.BUILDING == true then
            error("circular dependency on " .. target_atom.NAME)
        end

        target_atom.BUILDING = true
        prepare_prerequisites(target_atom)
        target_atom:BIND()

        local timestamp = target_atom:get_timestamp()

        local newest_prerequisite_time, newest_prerequisite =
            build_prepared_prerequisites(target_atom)
        local needs_building = target_needs_building(
            blud.command_line_options.always_make,
            newest_prerequisite_time,
            timestamp
        )
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
                target_atom:DO_ACTION(parent)
                blud.why.action_completed(target_atom)
                target_atom.TIMESTAMP = newest_timestamp
                timestamp = target_atom.TIMESTAMP
            elseif timestamp == oldest_timestamp then
                BLUD_EXIT(1000, target_atom.NAME)
            end
        end

        target_atom.TIMESTAMP = timestamp
        target_atom.BUILDING = false
        return timestamp, needs_building
    end
end

do  -- Internal update behavior for individual tests.
    local opBLUDTEST = register_operator(":BLUDTEST:")

    local function join_path(parent, child)
        if parent:match("[/\\]$") then
            return parent .. child
        end
        return parent .. "/" .. child
    end

    local function path_basename(path)
        local trimmed = path:gsub("[/\\]+$", "")
        local basename = trimmed:match("([^/\\]+)$")
        assert(basename, "path has no basename: " .. tostring(path))
        return basename
    end

    local function source_entries(directory)
        local entries = dircache.get_entries(directory)
        local names = {}

        -- Use the same cached view of the source tree as wildcard expansion.
        -- Sorting makes both the first reported mismatch and update order stable.
        for name in pairs(entries) do
            table.insert(names, name)
        end
        table.sort(names)
        return entries, names
    end

    -- Compare contents rather than timestamps. Reading in chunks keeps large
    -- test fixtures from becoming equally large temporary Lua strings.
    local function files_equal(from, to)
        if os_path_type(to) ~= 1 then
            return false
        end

        local from_file = assert(io.open(from, "rb"))
        local to_file = io.open(to, "rb")
        if not to_file then
            from_file:close()
            return false
        end

        local equal = true
        while true do
            local from_chunk = from_file:read(64 * 1024)
            local to_chunk = to_file:read(64 * 1024)
            if from_chunk ~= to_chunk then
                equal = false
                break
            end
            if from_chunk == nil then
                break
            end
        end

        from_file:close()
        to_file:close()
        return equal
    end

    -- A source directory contributes its contents directly to the destination.
    -- Only source entries matter: extra workspace files are deliberately ignored.
    local function compare_directory(from, to)
        if os_path_type(to) ~= 2 then
            return false
        end

        local entries, names = source_entries(from)
        for _, name in ipairs(names) do
            local from_child = join_path(from, name)
            local to_child = join_path(to, name)
            if entries[name].is_dir then
                if not compare_directory(from_child, to_child) then
                    return false
                end
            elseif not files_equal(from_child, to_child) then
                return false
            end
        end
        return true
    end

    -- The destination is always the test workspace. A file source is compared
    -- with workspace/basename(source); a directory source maps directly onto it.
    local function scompare(from, to)
        local from_type = os_path_type(from)
        if from_type == 0 then
            error("test source does not exist: " .. tostring(from))
        end
        if from_type == 2 then
            return compare_directory(from, to)
        end
        if os_path_type(to) ~= 2 then
            return false
        end
        return files_equal(from, join_path(to, path_basename(from)))
    end

    -- Report creation so testupdate can distinguish an added empty directory
    -- from a workspace that was already identical.
    local function ensure_directory(path)
        local path_type = os_path_type(path)
        if path_type == 2 then
            return false
        end
        if path_type ~= 0 then
            error("test destination is not a directory: " .. tostring(path))
        end
        if os_mkdir(path) == 2 then
            error("could not create test directory: " .. tostring(path))
        end
        return true
    end

    -- Avoid needless writes to identical files. Refuse to replace a workspace
    -- directory when the corresponding test source is a file.
    local function update_file(from, to)
        if files_equal(from, to) then
            return false
        end
        if os_path_type(to) == 2 then
            error(
                "cannot update test workspace: source is a file but " ..
                "destination is a directory: " ..
                tostring(from) .. " -> " .. tostring(to)
            )
        end
        if os_copy_file(from, to) ~= 0 then
            error(
                "could not update test file: " ..
                tostring(from) .. " -> " .. tostring(to)
            )
        end
        return true
    end

    -- Walk only the source tree: add or update corresponding entries without
    -- removing destination-only logs, pass markers, or other workspace files.
    local function update_directory(from, to)
        local updated = ensure_directory(to)
        local entries, names = source_entries(from)

        for _, name in ipairs(names) do
            local from_child = join_path(from, name)
            local to_child = join_path(to, name)
            local child_updated
            if entries[name].is_dir then
                child_updated = update_directory(from_child, to_child)
            else
                child_updated = update_file(from_child, to_child)
            end
            updated = child_updated or updated
        end
        return updated
    end

    -- Preserve exactly the same source-to-workspace mapping as scompare, and
    -- return whether any file or directory had to be created or changed.
    local function testupdate(from, to)
        local from_type = os_path_type(from)
        if from_type == 0 then
            error("test source does not exist: " .. tostring(from))
        end

        if from_type == 2 then
            return update_directory(from, to)
        end
        local updated = ensure_directory(to)
        return update_file(from, join_path(to, path_basename(from))) or updated
    end

    local function execute_test_action(rule, target, workspace, entry_name)
        local action_scope = blud.Scope:new(
            target.SCOPE,
            "test action(" .. target.NAME .. ")"
        )
        action_scope:set("<", entry_name)

        if blud.just_print(action_scope) then
            return rule.action(action_scope)
        end

        if AliasDir.push_cwd(workspace) ~= 0 then
            error("could not enter test workspace: " .. workspace)
        end

        local succeeded, status = pcall(rule.action, action_scope)
        local restore_result = AliasDir.pop_cwd()
        if restore_result ~= 0 then
            error("could not restore directory after test: " .. target.NAME)
        end
        if not succeeded then
            error(status, 0)
        end
        return status
    end

    function opBLUDTEST:EVAL_RULE()
        error(":BLUDTEST: is an internal operator")
    end

    function opBLUDTEST:BUILD(target)
        if target.BUILDING == true then
            error("circular dependency on " .. target.NAME)
        end
        target.BUILDING = true

        local rule = assert(
            target.RULE and target.RULE.operator == self and target.RULE,
            "test target does not belong to the :BLUDTEST: operator: " ..
            tostring(target.NAME)
        )
        local test_target = assert(
            rule.test_target,
            "test has no owning :TEST: target: " .. tostring(target.NAME)
        )
        local test_basename = assert(
            rule.test_basename,
            "test has no workspace basename: " .. tostring(target.NAME)
        )
        local source = assert(
            target.BOUND_NAME,
            "test has no bound source: " .. tostring(target.NAME)
        )

        for _, prerequisite in ipairs(
            atomize_words(rule.order_only_prereq_words or {})
        ) do
            prerequisite:BUILD(target)
        end

        -- Each test owns a directory below its suite in OWD. The source is
        -- copied there before execution; the source atom remains bound to the
        -- original path so timestamp caching never changes its identity.
        local workspace = join_path(
            join_path(target.SCOPE:get_text("OWD"), test_target.NAME),
            test_basename
        )
        local pass_path = join_path(workspace, "bludtest.pass")
        local source_changed = not scompare(source, workspace)

        -- In just-print mode the comparison still affects the decision, but
        -- no workspace files may be changed.
        if source_changed and not blud.just_print(target.SCOPE) then
            testupdate(source, workspace)
        end

        -- There is no single filesystem timestamp for a test result. Combine
        -- the known invalidation signals into mustrun.
        local mustrun = blud.command_line_options.always_make or
                        source_changed or
                        os_path_type(pass_path) ~= 1
        if mustrun then
            -- Remove any previous success before running so failure cannot
            -- leave a stale pass marker behind.
            if not blud.just_print(target.SCOPE) then
                local pass_type = os_path_type(pass_path)
                if pass_type == 2 then
                    error("test pass marker is a directory: " .. pass_path)
                end
                if pass_type ~= 0 and os_remove_file(pass_path) ~= 0 then
                    error("could not remove test pass marker: " .. pass_path)
                end
            end

            local status = execute_test_action(
                rule,
                target,
                workspace,
                test_basename
            )
            if status and status ~= 0 then
                assert(status >= 1 and status <= 256)
                BLUD_EXIT(status, target.NAME)
            end
            if not blud.just_print(target.SCOPE) then
                util.string_to_file(pass_path, "")
            end
        end

        -- The oldest timestamp is virtual here; mustrun reports whether this
        -- invocation selected the test action.
        target.TIMESTAMP = oldest_timestamp
        target.BUILDING = false
        return oldest_timestamp, mustrun
    end
end


do  -- Test targets aggregate one :BLUDTEST: rule per matched test.
    local op = register_operator(":TEST:")
    local bludtest_operator = blud.operators[":BLUDTEST:"]

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

    local function test_basename(test_name)
        local name = test_name:gsub("[/\\]+$", "")
        local basename = name:match("([^/\\]+)$")
        if not basename or basename == "." or basename == ".." then
            blud.error("#1: invalid test name.", test_name)
        end
        return basename
    end

    local function default_test_action(scope)
        return blud.execute(scope, "source " .. scope:get_text("<"))
    end

    local function append_unique(words, word)
        for _, existing in ipairs(words) do
            if existing == word then
                return
            end
        end
        table.insert(words, word)
    end

    -- a :TEST: name cannot be a primary target
    function op:SET_PRIMARY_TARGETS(target_atom)
        return nil
    end

    -- Test patterns are suite-relative, so ADD_RULE expands them after the
    -- suite target is known instead of using ordinary prerequisite globbing.
    function op:EVAL_RULE(
        left_tokens,
        right_tokens,
        action,
        order_only_prereq_words
    )
        self:ADD_RULES(
            left_tokens,
            right_tokens,
            action,
            order_only_prereq_words
        )
    end

    function op:ADD_RULE(
        target,
        prereq_words,
        action,
        order_only_prereq_words
    )
        action = action or default_test_action

        if not target.RULE then
            Operator.ADD_RULE(self, target, {}, nil)
        elseif target.RULE.operator ~= self then
            blud.error("#1: target used with more than one operator.", target.NAME)
        end

        local tests = expand_test_words(target.NAME, prereq_words)
        if #tests == 0 then
            blud.error("#1: :TEST: matched no tests.", target.NAME)
        end

        local target_rule = target.RULE
        for _, test in ipairs(tests) do
            local test_name = test.name
            local test_atom = blud.get_or_create_target(test_name)
            local basename = test_basename(test_name)
            local bound_name = test.source_directory and
                test.source_directory .. "/" .. test_name or test_name

            if test_atom.BOUND_NAME and test_atom.BOUND_NAME ~= bound_name then
                blud.error(
                    "#1: test atom has conflicting source bindings.",
                    test_name
                )
            end
            test_atom.BOUND_NAME = bound_name

            local is_new_test = true
            for _, existing_name in ipairs(target_rule.prereq_words) do
                if existing_name == test_name then
                    is_new_test = false
                    break
                elseif test_basename(existing_name) == basename then
                    blud.error(
                        "#1 and #2 have the same test basename.",
                        existing_name,
                        test_name
                    )
                end
            end

            if is_new_test then
                table.insert(target_rule.prereq_words, test_name)
            end

            local test_rule = test_atom.RULE
            if not test_rule then
                Operator.ADD_RULE(bludtest_operator, test_atom, {}, action)
                test_rule = test_atom.RULE
                test_rule.test_target = target
                test_rule.test_basename = basename
                test_rule.order_only_prereq_words = {}
            elseif test_rule.operator ~= bludtest_operator then
                blud.error(
                    "#1: test atom already belongs to another operator.",
                    test_name
                )
            elseif test_rule.test_target ~= target then
                blud.error(
                    "#1: test atom belongs to another :TEST: target.",
                    test_name
                )
            else
                test_rule.action = action
            end

            for _, order_only in ipairs(order_only_prereq_words or {}) do
                append_unique(test_rule.order_only_prereq_words, order_only)
            end
        end
    end

    function op:BUILD(target, parent)
        return Operator.BUILD(self, target, parent)
    end
end


-- :BUILD: operator
do
    local opBuild = register_operator(":BUILD:")
    local default_owd = AliasDir.to_absolute(".")

    local function expand_owd()
        local absolute_owd = default_owd

        if blud.build_atom then
            absolute_owd = assert(
                blud.build_atom.BOUND_NAME,
                "active build has no bound output directory"
            )
        end

        return AliasDir.to_relative(absolute_owd)
    end

    -- Default and named builds share this macro; its value will be derived
    -- whenever it is expanded rather than stored separately in each scope.
    local owd_macro = blud.Macro.from_function(expand_owd)

    local function activate_build(target)
        assert(target.SCOPE and target.SCOPE.target == target,
               "build has no owning target scope: " .. tostring(target.NAME))
        assert(target.RULE and target.RULE.operator == opBuild,
               "target does not belong to the :BUILD: operator: " ..
               tostring(target.NAME))

        blud.build_atom = target
        target.SCOPE:set_macro("OWD", owd_macro)
        blud.Scope.build.variables = target.SCOPE.variables
    end

    local function select_declared_build()
        for _, name in ipairs(blud.command_line_options.target_names or {}) do
            local target = blud.TARGETS[name]
            if target and target.RULE and target.RULE.operator == opBuild then
                return target
            end
        end
        return blud.default_build
    end

    function opBuild:INIT()
        if blud.build_atom then
            activate_build(blud.build_atom)
        else
            blud.Scope.build.variables = {}
            blud.Scope.build:set_macro("OWD", owd_macro)
        end
    end

    -- a build name cannot be a primary target
    function opBuild:SET_PRIMARY_TARGETS(target_atom)
        -- util.print("[:BUILD:]:SET_PRIMARY_TARGETS()")
        return nil
    end

    function opBuild:EVAL_RULE(left_tokens, right_tokens, action)
        -- Validate the written prerequisite list before ordinary globbing can
        -- discard an unmatched pattern.
        assert(#right_tokens == 0,
               ":BUILD: prerequisites are not supported for: " ..
               table.concat(left_tokens, ", "))
        Operator.EVAL_RULE(self, left_tokens, right_tokens, action)

        -- Rules following the declaration expand in the build selected on the
        -- command line, or in the first declared build when none was selected.
        activate_build(assert(select_declared_build()))
    end

    function opBuild:ADD_RULE(target, prereqs, action)
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
        target.BOUND_NAME = AliasDir.to_absolute(target.NAME)
        -- Important: do not call target:ADD_RULE().
        -- A :BUILD: declaration is not a build dependency rule.
        Operator.ADD_RULE(self, target, {}, nil)
    end

    function opBuild:BUILD(target)
        util.print("[:BUILD:]:BUILD(%s)", target.NAME)
        assert(target.SCOPE and target.SCOPE.target == target,
               "build has no owning target scope: " .. tostring(target.NAME))
        assert(target.RULE and target.RULE.operator == self,
               "build target does not belong to the :BUILD: operator: " ..
               tostring(target.NAME))
        activate_build(target)
        local owd = target.SCOPE:get_text("OWD")
        if not blud.just_print(target.SCOPE) then
            local mkdir_result = os_mkdir(owd)
            if mkdir_result == 2 then
                error("could not create build directory: " .. owd)
            end
        end
        return 0
    end
end

local operator_member_names = {
    "EVAL_RULE",
    "GLOB_TARGET_WORDS",
    "GLOB_PREREQUISITE_WORDS",
    "ATOMIZE_TARGET_WORDS",
    "ATOMIZE_PREREQUISITE_WORDS",
    "GROUP_TARGETS",
    "SET_PRIMARY_TARGETS",
    "ADD_RULES",
    "ADD_RULE",
    "BIND",
    "PREPARE_PREREQUISITES",
    "BUILD",
}

local operator_member_set = {}
for _, name in ipairs(operator_member_names) do
    assert(not operator_member_set[name],
           "duplicate debugger operator member: " .. name)
    assert(type(Operator[name]) == "function",
           "debugger operator member is not a function: " .. name)
    operator_member_set[name] = true
end

for name, value in pairs(Operator) do
    if type(value) == "function" and name ~= "operator_new" then
        assert(operator_member_set[name],
               "generic operator member is missing from the debugger: " ..
               tostring(name))
    end
end

debugger.register_operators(blud.operators, operator_member_names)

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
--        dircache.expand_pattern(entries, target.NAME, "*")
        dircache.expand_pattern(entries, "./test/*")
        util.print("glob: %s", util.dump(entries))
        error("die")
    else
        for i= 1, #prereq_atoms do
            local entries = {}
            local atom = prereq_atoms[i]
            dircache.expand_pattern(entries, prereq_atoms[i])
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
