local M = {}

local state
local reported = false

local function requested_name()
    return blud.command_line_options.why_target_name
end

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

local function decision_reason(timestamp, newest_prerequisite_time)
    if blud.command_line_options.always_make then
        return "always_make"
    elseif newest_prerequisite_time > timestamp then
        if timestamp == 0 then
            return "missing"
        end
        return "newer_prerequisite"
    end
    return "up_to_date"
end

function M.reached(target)
    if not matches(target) then
        return
    end

    local current = get_state()
    current.target = target
    current.reached = true
    current.visits = current.visits + 1
end

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
    current.built_reason = current.reason
    current.built_prerequisite = current.newest_prerequisite
end

local function quoted(name)
    return string.format("%q", name)
end

local function add_unique(values, seen, value)
    if not seen[value] then
        seen[value] = true
        table.insert(values, value)
    end
end

local function build_reverse_rules()
    local defined = {}
    local reverse = {}
    local reverse_seen = {}

    for _, rule in ipairs(blud.rules) do
        local prerequisites =
            rule.operator:GLOB_PREREQUISITE_WORDS(rule.prereq_words or {})

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
    local selected = {}
    for _, target in ipairs(primary_targets) do
        selected[target.NAME] = true
    end
    return selected
end

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
    elseif current and current.considered then
        print(string.format(
            "%s was not built because it was up to date.",
            quoted(name)
        ))
    else
        report_unreached(name, primary_targets)
    end
end

return M