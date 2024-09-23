-- implicit.lua: code to handle implicit rules
local implicit = {}

local rules = {}
local rule_count = 0

function implicit.literal_length(pattern)
    return #pattern:gsub("%%%%/", ""):gsub("%%", "")
end

function implicit.expand(pattern, stem, dir_stem)
    return pattern:gsub("%%%%/", dir_stem):gsub("%%", stem)
end

function implicit.add_rule(target, prerequisites, action)
    rule_count = rule_count + 1
    table.insert(rules, {
                     target        = target,
                     prerequisites = prerequisites,
                     action        = action,
                     order         = rule_count})
end



return implicit
