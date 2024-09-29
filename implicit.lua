-- implicit.lua: code to handle implicit rules
local implicit = {}

local rules = {}

function implicit.literal_length(pattern)
    return #pattern:gsub("%%%%/", ""):gsub("%%", "")
end

function implicit.expand(pattern, stem, dir_stem)
    return pattern:gsub("%%%%/", dir_stem):gsub("%%", stem)
end

function implicit.find_match(name, prerequisites)
    for _, prerequisite in ipairs(prerequisites) do
        local stem, dir_stem = match_pattern(name, prerequisite)
        if stem then
            return stem, dir_stem  -- Return the matched stem and dir_stem immediately
        end
    end
    return nil  -- No matches found
end


local rules_from_suffix = {}

function implicit.add_rule(target, prerequisites, action)
    -- Add the rule as usual
    local rule = {target = target, prerequisites = prerequisites, action = action, order = #rules + 1}
    table.insert(rules, rule)

    -- Populate rules_from_suffix and ensure each prerequisite has a literal suffix
    for _, prereq in ipairs(prerequisites) do
        local suffix = prereq:match("%.[^%%/.]*$")
        if not suffix then
            error("Prerequisite pattern does not contain a literal suffix: " .. prereq)
        end

        -- Add the rule to the rules_from_suffix table
        if not rules_from_suffix[suffix] then
            rules_from_suffix[suffix] = {}
        end
        table.insert(rules_from_suffix[suffix], rule)
    end
end

function implicit.match_pattern(name, pattern)
    -- Prepare Pattern A (with directory)
    local pattern_with_dir = "^" .. pattern
        :gsub("%%%%/", "(.+/)")
        :gsub("%%", "([^/]+)") .. "$"

    local dir_stem, stem = name:match(pattern_with_dir)
    if stem then
        return { name = name, stem = stem, dir_stem = dir_stem }
    end

    -- Prepare Pattern B (without directory)
    local pattern_without_dir = "^" .. pattern
        :gsub("%%%%/", "")
        :gsub("%%", "([^/]+)") .. "$"

    stem = name:match(pattern_without_dir)
    if stem then
        return { name = name, stem = stem, dir_stem = "" }
    end

    -- No match found
    return nil
end

function dump(t)
  local s = ""
  for k, v in pairs(t) do
    s = s .. k .. "=" .. v .. "\n"
  end
  return s
end

function parse_pattern(pattern)
    local result = {}

    -- Split pattern into directory and file based on the last '/'
    local dir, file = pattern:match("^(.-)([^/]*)$")
    print("dir = " .. dir .. " file = " .. file)

    -- Parse directory part for '%%/' operator
    if dir then
        result.pre_dir, result.post_dir = dir:match("^(.*)%%%%/(.*)$")
        if not result.pre_dir then
            result.pre_dir = dir
        end
    end

    -- Parse file part for '%' operator
    if file then
        result.pre_file, result.post_file = file:match("^(.*)%%(.+)$")
    end

    return result
end

-- simple unit tests
if true then
    local pattern, parsed
    pattern = "aaa/%%/bbb/ccc%ddd"
    parsed  = parse_pattern(pattern)
    assert(parsed.pre_dir == "aaa/")
    assert(parsed.post_dir == "bbb/")
    assert(parsed.pre_file == "ccc")
    assert(parsed.post_file == "ddd")
end


assert(false)

return implicit
