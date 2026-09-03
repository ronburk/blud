local AliasDir = require("aliasdir")
local DirCache = {}

--[[
directory_cache = {
    ["/absolute/path/to/dir"] = {
        ["."]       = <NUL-separated child names>,
        ["foo.c"]   = { name = ..., is_dir = ... },
        ["include"] = { name = ..., is_dir = ... },
        ...
    },
    ...
}

Each value is the table returned by get_dir_cache() for that directory.
The special "." entry is a NUL-separated string of child names used by
glob_expand(), not a filesystem entry.
]]
local directory_cache = {}

-- Helper function to get or create the directory cache
local function get_cached_dir(directory)
    -- Cache identity must not depend on the process current directory.
    local absolute_directory = AliasDir.to_absolute(directory)
    local cache = directory_cache[absolute_directory]
    if cache == nil then
        cache = get_dir_cache(absolute_directory)
        assert(cache)
        directory_cache[absolute_directory] = cache
    end
    return cache
end



-- Recursive function to handle glob pattern matching
local function recursive_glob_match(words, pattern_components, index, current_path, dir_cache)
    local match_count = 0  -- Keep track of matches

    -- Base case: if we've matched all components, add the full path to words
    if index > #pattern_components then
        table.insert(words, current_path)  -- Add the full matched path
        return 1  -- Count this as one match
    end

    local part = pattern_components[index]

    -- Handle "**" special case
    if part == "**" then
        -- "**" can match zero or more directories, so we need to try all possibilities:
        -- 1. Match zero directories: call recursively with the next pattern component
        match_count = match_count + recursive_glob_match(words, pattern_components, index + 1, current_path, dir_cache)

        -- 2. Match one or more directories: iterate through directories in dir_cache and recurse
        for name, entry in pairs(dir_cache) do
            if entry.is_dir then
                local subdir_cache = get_cached_dir(entry.name)  -- Recursively fetch the subdir cache
                -- Root components already end in a separator; avoid producing //.
                local separator = current_path:sub(-1) == "/" and "" or "/"
                local subdir_path = current_path ~= "" and
                    (current_path .. separator .. name) or name
                match_count = match_count + recursive_glob_match(words, pattern_components, index, subdir_path, subdir_cache)
            end
        end
    else
        -- Normal matching for the current component (using glob_expand for wildcards)
        local matched       = {}
        local matched_count = glob_expand(matched, part, dir_cache["."])
        if matched_count == 0 then
            return 0
        end

        -- For each matched entry, continue matching the remaining pattern components
        for _, matched_entry in ipairs(matched) do
            -- Root components already end in a separator; avoid producing //.
            local separator = current_path:sub(-1) == "/" and "" or "/"
            local full_path = current_path ~= "" and
                (current_path .. separator .. matched_entry) or matched_entry

            if index == #pattern_components then
                table.insert(words, full_path)
                match_count = match_count + 1
            else
                local next_dir_cache = get_cached_dir(full_path)
                match_count = match_count + recursive_glob_match(
                    words,
                    pattern_components,
                    index + 1,
                    full_path,
                    next_dir_cache
                                                                          )
            end
        end
    end

    return match_count  -- Return the number of matches found
end


--[[
path_split() returns path_components:

    relative:  { ".", "src", "**", "*.c" }
    Unix:      { "/", "usr", "include", "*.h" }
    Windows:   { "C:", "src", "*.c" }

The first component identifies the starting directory/root. Remaining
components are pathname/glob components consumed by recursive_glob_match().
]]
local function path_split(path)
    local components = {}
    local is_absolute = false

    -- Keep the Unix root as a component so absolute glob results stay absolute.
    if path:sub(1, 1) == "/" then
        table.insert(components, "/")
        path = path:sub(2)
        is_absolute = true
    -- Handle special paths: "\\.\", "\\?\"
    elseif string.match(path, "^\\\\%.") or string.match(path, "^\\\\%?") then
        local first_component = string.match(path, "^(\\\\[^\\]+\\?.-\\?\\?.*)")
        if first_component then
            table.insert(components, first_component)
            path = string.sub(path, #first_component + 1)
            is_absolute = true
        end
    -- Handle UNC paths: "\\server\share"
    elseif string.match(path, "^\\\\") then
        local unc_prefix = string.match(path, "^\\\\[^\\]+\\[^\\]+")
        if unc_prefix then
            table.insert(components, unc_prefix)
            path = string.sub(path, #unc_prefix + 1)
            is_absolute = true
        end
    -- Handle Drive letter paths (e.g., "C:" or "C:\")
    else
        local drive, rest_of_path = string.match(path, "^([a-zA-Z]:)(.*)")
        if drive then
            table.insert(components, drive)
            if rest_of_path:sub(1, 1) == "\\" or rest_of_path:sub(1, 1) == "/" then
                rest_of_path = rest_of_path:sub(2)  -- Remove leading slash
            end
            path = rest_of_path
            is_absolute = true
        end
    end
    
    -- Replace backslashes with forward slashes for uniform handling
    path = string.gsub(path, "\\", "/")

    -- Split path but respect [] wildcards
    local i = 1
    local part = ""
    local inside_brackets = false
    while i <= #path do
        local char = path:sub(i, i)
        
        if char == "[" then
            inside_brackets = true
            part = part .. char  -- Keep the '[' character
        elseif char == "]" then
            inside_brackets = false
            part = part .. char  -- Keep the ']' character
        elseif char == "/" and not inside_brackets then
            table.insert(components, part)
            part = ""  -- Reset part
        else
            part = part .. char  -- Accumulate the part
        end

        i = i + 1
    end

    -- Add the final part if it's non-empty
    if part ~= "" then
        table.insert(components, part)
    end

    -- If no absolute path component was found, ensure the first component is './'
    if not is_absolute and #components > 0 and not string.match(components[1], "^[a-zA-Z]:") then
        table.insert(components, 1, ".")
    end

    return components
end

local function split_parent(path)
    local parent, name = path:match("^(.*)/([^/]+)$")
    assert(parent and name, "path has no parent: " .. path)

    -- A drive root must retain its trailing separator ("C:/").
    if parent:match("^[A-Za-z]:$") then
        parent = parent .. "/"
    elseif parent == "" then
        parent = "/"
    end
    return parent, name
end

-- Main function to expand the glob pattern
function DirCache.expand_pattern(words, pattern)
    -- Split the pattern into path components
    local path_components = path_split(pattern)
    local dir = path_components[1]  -- Start with the root directory (or "." for current directory)

    -- Create a temporary table to store the new results
    local new_words = {}

    -- Call the recursive helper function to match the pattern, starting with an empty path
    local initial_cache = get_cached_dir(dir)  -- Cache for the root directory
    -- Preserve an absolute or drive/UNC root in emitted matches; only the
    -- synthetic current-directory root is omitted from relative results.
    local initial_path = dir == "." and "" or dir
    local match_count = recursive_glob_match(
        new_words,
        path_components,
        2,
        initial_path,
        initial_cache
    )

    -- If no matches were found, treat the pattern as a literal and add it to 'new_words'
--    if match_count == 0 then
--        table.insert(new_words, pattern)
--    end

    if match_count > 0 then
        -- Sort the new words
        table.sort(new_words)

        -- Append the sorted new_words to words
        for _, word in ipairs(new_words) do
            table.insert(words, word)
        end
    end
    return match_count
end

-- Return the cached metadata for one path, or nil when it is unavailable.
function DirCache.get_timestamp(path)
    local absolute_path = AliasDir.to_absolute(path)
    local parent, name = split_parent(absolute_path)
    local ok, entries = pcall(get_cached_dir, parent)
    if not ok then
        return nil
    end

    local entry = entries[name]
    return entry and entry.timestamp or nil
end

-- Return the cached directory table.  The reserved "." key is matcher data,
-- not an entry, and callers must not treat it as one.
function DirCache.get_entries(directory)
    return get_cached_dir(directory)
end

return DirCache
