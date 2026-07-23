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

local function goal_description(primary_targets)
    if blud.command_line_options.target_names then
        local names = {}
        for _, target in ipairs(primary_targets) do
            table.insert(names, quoted(target.NAME))
        end
        if #names == 1 then
            return "the requested target " .. names[1]
        end
        return "the requested targets " .. table.concat(names, ", ")
    end

    if blud.default_target then
        return "the default target " .. quoted(blud.default_target.NAME)
    end
    return "the selected build"
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
    local target = blud.TARGETS[name]

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
    elseif target then
        print(string.format(
            "%s was not built because it was not needed to build %s.",
            quoted(name),
            goal_description(primary_targets)
        ))
    else
        print(string.format(
            "%s was not built because no target with that name was defined.",
            quoted(name)
        ))
    end
end

return M