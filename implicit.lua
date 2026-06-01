-- implicit.lua: code to handle implicit rules
local implicit = {}

local rules = {}
local rules_from_suffix = {}


function implicit.find_forward(target_name, exists)
    for i = 1, #rules do
        local rule = rules[i]
        util.print("implicit, rule is %s", util.dump(rule))
        local match = implicit.match_pattern(target_name, rule.target)
        util.print("implicit, match is %s", util.dump(match))
        if match then
            local prereq_names = {}
            local ok = true
            for j = 1, #rule.prerequisites do
                local prereq_pattern = rule.prerequisites[j]
                local prereq_name = implicit.expand_pattern(prereq_pattern, match)

                if not get_path_timestamp(prereq_name) then
                    ok = false
                    break
                end
                prereq_names[#prereq_names + 1] = prereq_name
            end
            if ok then
                return rule, match, prereq_names
            end
        end
    end

    return nil
end


function implicit.literal_length(pattern)
    return #pattern:gsub("%%%%/", ""):gsub("%%", "")
end

function implicit.expand(pattern, stem, dir_stem)
    return pattern:gsub("%%%%/", dir_stem):gsub("%%", stem)
end

function implicit.find_match(name, prerequisites)
    for _, prerequisite in ipairs(prerequisites) do
        local stem, dir_stem = match_parsed_pattern(name, prerequisite)
        if stem then
            return stem, dir_stem  -- Return the matched stem and dir_stem immediately
        end
    end
    return nil  -- No matches found
end


-- find_reverse: find a rule with a prerequisite pattern that matches a given name
function implicit.find_reverse(prereq_name)
    local suffix = prereq_name:match("%.[^/.]+$")
    local candidates = rules_from_suffix[suffix] or {}
    for i = #candidates, 1, -1 do
        local rule = candidates[i]
        for _, prereq in ipairs(rule.prerequisites) do
            local dir_stem, file_stem = match_parsed_pattern(parse_pattern(prereq), prereq_name)
            if dir_stem then
                return rule, file_stem, dir_stem
            end
        end
    end
    return nil
end


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

-- Match a concrete name against an unparsed implicit-rule pattern.
--
-- Returns:
--     { name = name, stem = stem, dir_stem = dir_stem }
--
-- or nil if the pattern does not match.
--
-- '%' captures a non-empty filename stem that does not contain '/'.
-- '%%/' captures zero or more directory components, including the trailing
-- slash when non-empty. When '%%/' matches nothing, dir_stem is "".
-- Examples:
--     name                    pattern             result
--     "cstr.o"                "%.o"               { stem = "cstr", dir_stem = "" }
--     "src/foo/cstr.o"        "src/%%/%.o"        { stem = "cstr", dir_stem = "foo/" }
--     "src/cstr.o"            "src/%%/%.o"        { stem = "cstr", dir_stem = "" }
function implicit.match_pattern(name, pattern)
    local result = nil -- assume no match

    -- We can translate this pattern style to Lua pattern format, but
    -- must handle two cases because Lua patterns don't support alternation
    -- "src/%%/%.o" => "src/(.*/)?([^/]+)\.o"  (if we had true regular expressions)

    -- first case is when a "%%/" operator matches something
    local pattern_with_dir = "^" .. pattern
        :gsub("%%%%/", "(.+/)")
        :gsub("%%", "([^/]+)") .. "$"

    local dir_stem, stem = name:match(pattern_with_dir)
    if stem then
        result =  { name = name, stem = stem, dir_stem = dir_stem }
    else
        -- second case is when a "%%/" operator must match the empty string
        local pattern_without_dir = "^" .. pattern
            :gsub("%%%%/", "")
            :gsub("%%", "([^/]+)") .. "$"

        stem = name:match(pattern_without_dir)
        if stem then
            result =  { name = name, stem = stem, dir_stem = "" }
        end
    end

    return result
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
    local msg    = nil

    -- Split pattern into directory and file based on the last '/'
    local dir, file = pattern:match("^(.-)([^/]*)$")

    -- Parse directory part for '%%/' operator
    if dir then
        local operator_count = select(2, dir:gsub("%%%%/", ""))
        if operator_count > 1 then
            msg = string.format("%q: only one '%%/' operator allowed.")
        elseif operator_count == 1 then
            result.pre_dir, result.post_dir = dir:match("^(.*)%%%%/(.*)$")
        else
            result.predir = dir
            result.postdir = ""
            result.pre_dir, result.post_dir = dir:match("^(.*)%%%%/(.*)$")
            if not result.pre_dir then -- if no directory match operator
                result.pre_dir = dir   -- then entire literal string belongs to pre_dir
            end
            if not result.post_dir then result.post_dir = "" end
        end
        if result.pre_dir:find("%%") or result.post_dir:find("%%") then
            msg = string.format("%q: '%' operator not allowed in directory prefix.")
        end
    end
    if msg then error(msg) end

    -- Parse file part for '%' operator
    if file then
        result.pre_file, result.post_file = file:match("^([^%%]*)%%([^%%]*)$")
    end

    return result
end

function match_parsed_pattern(pattern, path)
    local dir_stem, file_stem

    -- Separate the path into directory and filename components
    local dir_path, file_path = path:match("^(.-)([^/]*)$")

    -- Match directory pattern
    if pattern.pre_dir or pattern.post_dir then
        local dir_pattern = (pattern.pre_dir or '') .. '(.*)' .. (pattern.post_dir or '')
        dir_stem = dir_path:match(dir_pattern)
    else
        dir_stem = "" -- No directory patterns means match any
    end

    -- Match file pattern
    if pattern.pre_file or pattern.post_file then
        local file_pattern = (pattern.pre_file or '') .. '(.*)' .. (pattern.post_file or '')
        file_stem = file_path:match(file_pattern)
    else
        file_stem = "" -- No file patterns means match any
    end

    -- Return nil if either part did not match
    if not dir_stem or not file_stem then
        return nil
    end

    return dir_stem, file_stem
end


-- simple unit tests
if true then
    function test_parse(pattern, pre_dir, post_dir, pre_file, post_file)
        local parsed = parse_pattern(pattern)
        local msg = string.format("pattern=%q\n" ..
            "pre_dir=%q, expected=%q\n" ..
            "post_dir=%q, expected=%q\n" ..
            "pre_file=%q, expected=%q\n" ..
            "post_file=%q, expected=%q\n",
            pattern,
            parsed.pre_dir, pre_dir,
            parsed.post_dir, post_dir,
            parsed.pre_file, pre_file,
            parsed.post_file, post_file
        )
        if  pre_dir ~= parsed.pre_dir or
            post_dir ~= parsed.post_dir or
            pre_file ~= parsed.pre_file or
            post_file ~= parsed.post_file then
            error(msg)
            end
    end
    test_parse("src/%%/build%", "src/", "", "build", "")
    function test_pattern(pattern, path, dir_stem_expected, file_stem_expected)
        local parsed, dir_stem, file_stem        
        parsed = parse_pattern(pattern)
        dir_stem, file_stem = match_parsed_pattern(parsed, path)
        local msg = string.format("pattern=%q, path=%q\n" ..
                               "dir_stem=%q, expected=%q\n" ..
                               "file_stem=%q, expected=%q\n",
                               pattern, path, dir_stem, dir_stem_expected, file_stem, file_stem_expected)
        if dir_stem ~= dir_stem_expected then
            error(msg)
        end
        if file_stem ~= file_stem_expected then
            error(msg)
        end
    end
    
    test_pattern("aaa/%%/bbb/ccc%ddd", "aaa/bbb/cccxxddd", "", "xx")

    -- Testing with a directory and file pattern
    test_pattern("src/%%/build%file", "src/project/build123file", "project/", "123") -- dir and file stems
    test_pattern("src/%%/build%file", "src/buildfile", "", "") -- Should match with empty stems
    test_pattern("src/%%/build%", "src/temp/buildfile", "temp/", "file") -- Check dir stem with file pattern ending in %

    -- Testing with only directory pattern
    test_pattern("data/%%/", "data/some/other/", "some/other/", "") -- Entire path as dir_stem
    test_pattern("data/%%/", "data/test/", "test/", "") -- Single directory as dir_stem
    test_pattern("data/", "datafile", nil, nil) -- Mismatch; no trailing slash in path

    -- Testing with only file pattern
    test_pattern("%file.txt", "myfile.txt", "", "my") -- Simple file stem extraction
    test_pattern("file%", "file123", "", "123") -- File stem with suffix pattern
    test_pattern("nofile%", "random.txt", nil, nil) -- No match; pattern does not fit

    -- Testing exact matches without patterns
    test_pattern("folder/subfolder/", "folder/subfolder/", "", "") -- Directories exactly matching
    test_pattern("singlefile.txt", "singlefile.txt", "", "") -- File exactly matching

    -- Test edge cases
    test_pattern("%%/file", "dir/file", "dir/", "") -- Edge case for no file pattern
    test_pattern("folder/%%", "folder/", "", "") -- Edge case for empty directory match
    test_pattern("folder/%file", "folder/newfile", "", "new") -- Pattern with directory and file

end


--error("implicit.lua exits because we are temporarily testing")

return implicit
