-- implicit.lua: code to handle implicit rules
local implicit = {}

local rules = {}
local rules_from_suffix = {}


local function parse_pattern(pattern)
    local result = {pre_dir="",post_dir="",pre_file="",post_file=""}
    local msg    = nil

    if pattern:find("%%%%[^/]") or pattern:match("%%%%$") then
        msg = string.format(
            "%q: '%%%%' is not legal; use '%%%%/' for a directory wildcard.",
            pattern)
        result = nil
    else
        -- Split pattern into directory & file based on final '/'
        local dir, file = pattern:match("^(.-)([^/]*)$") -- always succeeds

        -- Parse directory part for '%%/' operator
        if dir then
            local _,operator_count = dir:gsub("%%%%/", "")
            if operator_count > 1 then
                msg = string.format("%q: only one '%%%%/' operator allowed.", pattern)
            elseif operator_count == 1 then
                result.pre_dir, result.post_dir = dir:match("^(.*)%%%%/(.*)$")
            else  -- there is no '%%/' operator
                result.pre_dir = dir
            end
            if result.pre_dir:find("%%") or result.post_dir:find("%%") then
                msg = string.format(
                    "%q: '%%' operator not allowed in directory prefix.", pattern)
            end
        end
        if msg then
            result = nil
        else -- now handle file, which can't produce an error
            -- no alternation in Lua patterns, must use two cases:
            -- a) '%' char is present and b) '%' char is not present
            if file then
                result.pre_file, result.post_file = file:match("^([^%%]*)%%([^%%]*)$")
                if not result.pre_file then -- if there was no '%' char
                    result.pre_file  = file
                    result.post_file = ""
                end
            end
        end
    end
    return result, msg
end



-- find_forward: find pattern rule whose target matches this target
--
-- Given a concrete target name, find the first implicit rule whose target
-- pattern matches it and whose prerequisite patterns expand to existing files.
--
-- Example:
--     target_name       "cstr.o"
--     rule.target       "%.o"
--     rule.prerequisites { "%.c" }
--     match             { name = "cstr.o", stem = "cstr", dir_stem = "" }
--     prereq_names      { "cstr.c" }
--
-- Returns:
--     rule, match, prereq_atoms
--
-- or nil if no implicit rule applies.
function implicit.find_forward(target_name, exists)
    for i = 1, #rules do
        local rule = rules[i]
        util.print("implicit, rule is %s", util.dump(rule))
        local match = implicit.match_pattern(target_name, rule.target)
        util.print("implicit, match is %s", util.dump(match))
        if match then -- if target_name matches this pattern rule
            local prereq_words = {}
            local ok = true
            for j = 1, #rule.prerequisites do -- do prerequisites exist?
                local prereq_pattern = rule.prerequisites[j]
                local prereq_word    = implicit.expand(prereq_pattern, match.stem, match.dir_stem)
                if not get_path_timestamp(prereq_word) then
                    ok = false
                    break
                end
                prereq_words[#prereq_atoms + 1] = blud.get_or_create_target(prereq_word)
            end
            if ok then
                return rule, match, prereq_words
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


-- find_reverse: find pattern rule whose prerequiste matches this prerequisite
--
-- Given a concrete prerequisite/source name, find an implicit rule whose
-- prerequisite pattern matches it. This supports source-to-target inference.
--
-- Example:
--     prereq_name        = "cstr.c"
--     rule.target        = "%.o"
--     rule.prerequisites = { "%.c" }
--     file_stem          = "cstr"
--     dir_stem           = ""
--
-- Returns:
--     rule, file_stem, dir_stem
--
-- or nil if no implicit rule applies.
function implicit.find_reverse(prereq_name)
    local suffix = prereq_name:match("%.[^/.]+$")
    local candidates = rules_from_suffix[suffix] or {}
    for i = #candidates, 1, -1 do
        local rule = candidates[i]
        for _, prereq in ipairs(rule.prerequisites) do
            local parsed_pattern, err = parse_pattern(prereq)
            local dir_stem, file_stem = match_parsed_pattern(parsed_pattern, prereq_name)
            if dir_stem then
                return rule, file_stem, dir_stem
            end
        end
    end
    return nil
end


-- add a rule to the implicit rule database
function implicit.add_rule(target, prerequisites, action)
    util.print("implicit.add_rule(%s,%s,action)", util.dump(target), util.dump(prerequisites))
    local parsed, errmsg
    -- Add the rule as usual
    local rule = {target = target, prerequisites = prerequisites, action = action, order = #rules + 1}
    table.insert(rules, rule)
    parsed, errmsg = parse_pattern(target)
    if not parsed then return errmsg end
    rule.parsed_target = parsed
    -- Populate rules_from_suffix and ensure each prerequisite has a literal suffix
    rule.parsed_prerequisites = {}
    for _, prereq in ipairs(prerequisites) do
        local suffix = prereq:match("%.[^%%/.]*$")
        if not suffix then
            return string.format(
                "Prerequisite pattern does not contain a literal suffix: '%q'", prereq)
        end
        parsed, errmsg = parse_pattern(prereq)
        if not parsed then return errmsg end
        table.insert(rule.parsed_prerequisites, parsed)
        -- Add the rule to the rules_from_suffix table
        if not rules_from_suffix[suffix] then
            rules_from_suffix[suffix] = {}
        end
        table.insert(rules_from_suffix[suffix], rule)
    end
    return errmsg
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

-- ???TODO are we escaping chars in 'pattern' that collide with lua special pattern chars?
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


---[=[UNIT_TESTS

function test_parse(pattern, pre_dir, post_dir, pre_file, post_file)
    local parsed,msg = parse_pattern(pattern)
    if not parsed then
        util.print("test_parse of %q failed: %s", pattern, msg)
        return
    else
        util.print("parsed=%s", util.dump(parsed))
    end
    msg = string.format("pattern=%q\n" ..
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
    if  pre_dir   ~= parsed.pre_dir   or
        post_dir  ~= parsed.post_dir  or
        pre_file  ~= parsed.pre_file  or
        post_file ~= parsed.post_file then
        util.print("FAIL: %s", msg)
    end
end
test_parse("src/%%/build%", "src/", "", "build", "")
test_parse("singlefile.txt", "", "", "singlefile.txt", "")
test_parse("folder/%%", "folder/", "", "") -- Edge case for empty directory match

function test_pattern(pattern, path, dir_stem_expected, file_stem_expected)
    local parsed, msg, dir_stem, file_stem        
    parsed, msg = parse_pattern(pattern)
    if not parsed then
        util.print("test_pattern of %q failed: %s", pattern, msg)
        return
    end
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

test_pattern("singlefile.txt", "otherfile.txt", nil, nil)

--]=]

--error("implicit.lua exits because we are temporarily testing")

return implicit
