--[[
    --why TARGET

Run the build selected by the positional arguments, or by the default target
when no positional argument is present. Afterward, explain why the target named
TARGET was or was not built. TARGET selects only the subject of the
explanation; it does not add that target to the build.

In this file, TARGET in a comment means the string following --why. A parameter
named target is an atom representing a target. primary_targets contains the
atoms selected by the positional arguments or the default target; diagnostic
messages call these "root targets." "Reached" means that atom.BUILD() was
called for the atom.

atom.BUILD() calls reached() before it tries to bind the target or find an
implicit rule. Once the target's rebuild status is known, considered() saves
the timestamps and result. action_started() and action_completed() surround
the action. report() turns these saved facts into the explanation.

If reached() was never called for TARGET, no build event explains its absence.
report_unreached() instead reads the rules already present in blud.rules. It
does not bind names, discover an implicit rule for TARGET, or ask an operator
to prepare prerequisites.

Normal completion and error handling can both call report(). reported prevents
the second call from printing the explanation again.
]]

local M = {}

-- Every hook call for an atom whose NAME equals TARGET updates state.
-- considered() replaces the saved timestamp data on each call.
-- state.action_started and state.built are never cleared, so a later call
-- cannot erase evidence that an action began or completed.
local state
local reported = false

local function requested_name()
    return blud.command_line_options.why_target_name
end

-- Hook parameters are atoms. Match the atom's NAME exactly to TARGET;
-- BOUND_NAME is not considered here.
local function matches(target)
    local name = requested_name()
    return name and target.NAME == name
end

local function get_state()
    if not state then
        state = {
            name = requested_name(),
            visits = 0,
            considerations = 0,
        }
    end
    return state
end

local function has_action(target)
    return target.RULE and target.RULE.action ~= nil
end

-- Classify the pre-action timestamps for report(). considered() stores the
-- result now because an action may change the target file's timestamp.
local function decision_reason(timestamp, newest_prerequisite_time)
    if blud.command_line_options.always_make then
        return "always_make"
    elseif timestamp == 0 then
        return "missing"
    elseif newest_prerequisite_time > timestamp then
        return "newer_prerequisite"
    end
    return "up_to_date"
end

-- atom.BUILD() calls this first, before that call sets the parent scope, looks
-- for an implicit rule, or binds the target. reached therefore means that the
-- update traversal attempted this atom, not that its rebuild status is known.
function M.reached(target)
    if not matches(target) then
        return
    end

    local current = get_state()
    current.target = target
    current.reached = true
    current.visits = current.visits + 1
end

-- Record one call's needs_building result. For an atom with a rule, its
-- operator calls this after binding it, building its prerequisites, and
-- computing needs_building from the timestamps. atom.BUILD() also calls this
-- for an existing atom with no rule, passing false for needs_building.
function M.considered(
    target,
    timestamp,
    newest_prerequisite_time,
    newest_prerequisite,
    needs_building
)
    if not matches(target) then
        return
    end

    local current = get_state()
    current.target = target
    current.considered = true
    current.considerations = current.considerations + 1
    current.timestamp = timestamp
    current.newest_prerequisite_time = newest_prerequisite_time
    current.newest_prerequisite = newest_prerequisite
    current.needs_building = needs_building
    current.has_action = has_action(target)
    current.reason = decision_reason(timestamp, newest_prerequisite_time)
end

-- Operators call action_started() immediately before target:DO_ACTION(), and
-- action_completed() only after it returns normally. If only action_started()
-- was called, target:DO_ACTION() did not return normally. "Completed" means
-- that the action returned; it does not mean that a target file exists.
function M.action_started(target)
    if not matches(target) then
        return
    end

    get_state().action_started = true
end

function M.action_completed(target)
    if not matches(target) then
        return
    end

    local current = get_state()
    current.built = true
    -- A later considered() call may replace reason and newest_prerequisite.
    -- Preserve the values associated with the action that just returned.
    current.built_reason = current.reason
    current.built_prerequisite = current.newest_prerequisite
end

local function quoted(name)
    return string.format("%q", name)
end

-- Keep an ordered list without duplicates. seen records the values already in
-- values. build_reverse_rules() uses this to list each target name once for a
-- prerequisite; find_roots() uses it to return each result name once when
-- several paths end at that name.
local function add_unique(values, seen, value)
    if not seen[value] then
        seen[value] = true
        table.insert(values, value)
    end
end

-- For every target/prerequisite pair in blud.rules, add target.NAME to
-- reverse[prerequisite_name]. For the rule "output: input", reverse["input"]
-- contains "output". report_unreached() can therefore start with TARGET and
-- repeatedly find target names whose rules list the current name as a
-- prerequisite. defined records every name that appears as a rule target.
local function build_reverse_rules()
    local defined = {}
    local reverse = {}
    local reverse_seen = {}

    for _, rule in ipairs(blud.rules) do
        local prerequisites = rule.prereq_words or {}

        for _, target in ipairs(rule.targets or {}) do
            local target_name = target.NAME
            defined[target_name] = true

            for _, prerequisite_name in ipairs(prerequisites) do
                local parents = reverse[prerequisite_name]
                if not parents then
                    parents = {}
                    reverse[prerequisite_name] = parents
                    reverse_seen[prerequisite_name] = {}
                end
                add_unique(
                    parents,
                    reverse_seen[prerequisite_name],
                    target_name
                )
            end
        end
    end

    return defined, reverse
end

-- Follow reverse until a name has no entry in reverse. find_roots() calls such
-- a name a root: it appears as a rule target, but no declared rule lists it as
-- a prerequisite. This is a property of all declared rules, independent of
-- whether the name is one of this invocation's primary_targets. A closed cycle
-- with no path out of the cycle produces no root.
local function find_roots(name, reverse)
    local roots = {}
    local root_seen = {}
    local visiting = {}
    local visited = {}

    local function visit(current)
        if visiting[current] or visited[current] then
            return
        end

        visiting[current] = true

        local parents = reverse[current]
        if not parents or #parents == 0 then
            add_unique(roots, root_seen, current)
        else
            for _, parent in ipairs(parents) do
                visit(parent)
            end
        end

        visiting[current] = nil
        visited[current] = true
    end

    visit(name)
    return roots
end

local function selected_targets(primary_targets)
    -- Convert the atoms selected by the command line or default target into a
    -- set of NAME values for comparison with the roots from find_roots().
    local selected = {}
    for _, target in ipairs(primary_targets) do
        selected[target.NAME] = true
    end
    return selected
end

-- This function is called only when no atom whose NAME equals TARGET called
-- reached(). For each root found through the declared rules, report whether it
-- was selected as one of primary_targets. A selected root should ordinarily
-- have caused traversal to reach TARGET; if it did not, the declared rules do
-- not supply a cause, so report that fact instead of inventing one.
local function report_unreached(name, primary_targets)
    local defined, reverse = build_reverse_rules()
    if not defined[name] then
        print(string.format(
            "%s was not built because no target with that name was defined.",
            quoted(name)
        ))
        return
    end

    local roots = find_roots(name, reverse)
    if #roots == 0 then
        print(string.format(
            "%s was not built, but no path to a root could be determined.",
            quoted(name)
        ))
        return
    end

    local selected = selected_targets(primary_targets)
    for _, root in ipairs(roots) do
        if selected[root] then
            if root == name then
                print(string.format(
                    "%s was not built even though it was a root target.",
                    quoted(name)
                ))
            else
                print(string.format(
                    "%s was not built even though %s was a root target.",
                    quoted(name),
                    quoted(root)
                ))
            end
        elseif root == name then
            print(string.format(
                "%s was not built because it was not a root target.",
                quoted(name)
            ))
        else
            print(string.format(
                "%s was not built because %s was not built because " ..
                "it was not a root target.",
                quoted(name),
                quoted(root)
            ))
        end
    end
end

-- Turn decision_reason()'s code into the clause printed after "because".
-- prerequisite is the atom that had the greatest prerequisite timestamp when
-- reason is "newer_prerequisite".
local function rebuild_reason(reason, prerequisite)
    if reason == "always_make" then
        return "-B was specified"
    elseif reason == "missing" then
        return "the target file did not exist"
    elseif reason == "newer_prerequisite" then
        if prerequisite then
            return "prerequisite " .. quoted(prerequisite.NAME) .. " was newer"
        end
        return "a prerequisite was newer"
    end
    return "it was out of date"
end

function M.report(primary_targets)
    if reported then
        return
    end
    reported = true

    local name = requested_name()
    if not name then
        return
    end

    local current = state
    -- considered means only that needs_building was calculated. If it is true,
    -- the other fields distinguish no action, an action not started, an action
    -- started, and an action completed. Check built first because a later
    -- considered() call can replace the timestamp data saved for that action.
    if current and current.built then
        print(string.format(
            "%s was built because %s.",
            quoted(name),
            rebuild_reason(
                current.built_reason,
                current.built_prerequisite
            )
        ))
    elseif current and current.needs_building and not current.has_action then
        print(string.format(
            "%s was not built: it needed rebuilding because %s, " ..
            "but no action was defined.",
            quoted(name),
            rebuild_reason(
                current.reason,
                current.newest_prerequisite
            )
        ))
    elseif current and current.considered and not current.needs_building then
        print(string.format(
            "%s was not built because it was up to date.",
            quoted(name)
        ))
    elseif current and current.action_started then
        print(string.format(
            "%s was not built: it needed rebuilding because %s, " ..
            "and its action started but did not complete.",
            quoted(name),
            rebuild_reason(
                current.reason,
                current.newest_prerequisite
            )
        ))
    elseif current and current.considered and current.needs_building then
        print(string.format(
            "%s was not built: it needed rebuilding because %s, " ..
            "but its action was not started.",
            quoted(name),
            rebuild_reason(
                current.reason,
                current.newest_prerequisite
            )
        ))
    elseif current and current.reached then
        print(string.format(
            "%s was not built: it was reached, but its build status " ..
            "was not determined.",
            quoted(name)
        ))
    else
        report_unreached(name, primary_targets)
    end
end

return M
