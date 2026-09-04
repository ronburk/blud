--[[
AliasDir manages logical directory aliases across temporary changes to the
process current directory. It stores directory identities as absolute paths and
converts them to paths relative to the current directory when actions expand
aliases. Current path/link-boundary handling is intentionally lexical and does
not yet account for symbolic-link crossings.
]]

local AliasDir = {}

local initial_cwd = assert(os_getcwd())
local is_windows = initial_cwd:match("^[A-Za-z]:[/\\]") or
                      initial_cwd:sub(1, 2) == "\\\\"
local logical_cwd
local logical_cwd_stack = {}

-- Use one separator internally; the OS-facing functions accept either form.
local function normalize_separators(path)
    return (path:gsub("\\", "/"))
end

-- Split an absolute path into its root prefix and remaining components.
-- A root is the part that cannot be traversed above: '/', 'C:/', or '//host/share'.
local function split_absolute_root(path)
    local drive_letter, path_tail = path:match("^([A-Za-z]:)/(.*)$")
    if drive_letter then
        return drive_letter .. "/", path_tail
    end

    if path:sub(1, 2) == "//" then
        local unc_server, unc_share, path_tail = path:match("^//([^/]+)/([^/]+)/*(.*)$")
        if unc_server then
            return "//" .. unc_server .. "/" .. unc_share, path_tail
        end
    elseif path:sub(1, 1) == "/" then
        return "/", path:sub(2)
    end
end

-- Append ordinary path components, resolving '.' and cancellable '..' pairs.
-- This is lexical normalization; it deliberately does not inspect the filesystem.
local function append_normalized_components(components, path)
    for component in path:gmatch("[^/]+") do
        if component == ".." then
            if #components > 0 then
                components[#components] = nil
            end
        elseif component ~= "." then
            components[#components + 1] = component
        end
    end
end

-- Reconstruct an absolute path from its unchanged root and normalized components.
local function join_absolute_path(root, components)
    if #components == 0 then
        return root
    end
    local separator = root:sub(-1) == "/" and "" or "/"
    return root .. separator .. table.concat(components, "/")
end

-- Return the root and normalized component list for an absolute path.
local function split_absolute_path(path)
    path = normalize_separators(path)
    local root, path_tail = split_absolute_root(path)
    assert(root, "path is not absolute: " .. path)

    local components = {}
    append_normalized_components(components, path_tail)
    return root, components
end

-- Canonicalize separators and '.', '..' in an absolute path without filesystem I/O.
local function normalize_absolute_path(path)
    local root, components = split_absolute_path(path)
    return join_absolute_path(root, components)
end

initial_cwd = normalize_absolute_path(initial_cwd)
logical_cwd = initial_cwd

function AliasDir.get_cwd()
    return logical_cwd
end

function AliasDir.to_absolute(path)
    path = normalize_separators(path)
    assert(path ~= "", "empty path")

    -- On Windows, '\\foo' means root-relative on the current drive, while
    -- '\\\\server\\share' is a complete UNC root handled by split_absolute_root().
    if is_windows and path:sub(1, 1) == "/" and
       path:sub(1, 2) ~= "//" then
        local current_root = split_absolute_root(logical_cwd)
        local drive_letter = current_root:match("^([A-Za-z]:)/$")
        assert(drive_letter, "cannot resolve a root-relative path without a drive: " .. path)
        path = drive_letter .. path
    end

    local root = split_absolute_root(path)
    if root then
        return normalize_absolute_path(path)
    end

    local drive_letter, path_tail = path:match("^([A-Za-z]:)(.*)$")
    local current_root, components = split_absolute_path(logical_cwd)
    if drive_letter then
        assert(current_root:sub(1, 2):lower() == drive_letter:lower(),
               "cannot resolve a path relative to another drive: " .. path)
        path = path_tail
    end

    append_normalized_components(components, path)
    return join_absolute_path(current_root, components)
end

local function path_component_equal(left, right)
    -- Windows path components are case-insensitive; Unix components are not.
    if is_windows then
        return left:lower() == right:lower()
    end
    return left == right
end

function AliasDir.to_relative(path)
    local target_root, target_components = split_absolute_path(path)
    local current_root, current_components = split_absolute_path(logical_cwd)
    local absolute = join_absolute_path(target_root, target_components)

    if not path_component_equal(target_root, current_root) then
        return absolute
    end

    -- Remove the shared prefix, then add '..' for each remaining current-dir part.
    local common_component_count = 0
    while current_components[common_component_count + 1] and
          target_components[common_component_count + 1] and
          path_component_equal(current_components[common_component_count + 1],
                          target_components[common_component_count + 1]) do
        common_component_count = common_component_count + 1
    end

    local relative_components = {}
    for _ = common_component_count + 1, #current_components do
        relative_components[#relative_components + 1] = ".."
    end
    for index = common_component_count + 1, #target_components do
        relative_components[#relative_components + 1] = target_components[index]
    end
    return #relative_components == 0 and "." or table.concat(relative_components, "/")
end

function AliasDir.set_cwd(path)
    -- Keep the logical path synchronized only after the OS changes directory.
    local absolute = AliasDir.to_absolute(path)
    local result = os_setcwd(absolute)
    if result == 0 then
        logical_cwd = absolute
    end
    return result
end

function AliasDir.push_cwd(path)
    -- Save the prior logical directory only when entering the requested one works.
    local previous = logical_cwd
    local result = AliasDir.set_cwd(path)
    if result == 0 then
        logical_cwd_stack[#logical_cwd_stack + 1] = previous
    end
    return result
end

function AliasDir.pop_cwd()
    assert(#logical_cwd_stack > 0, "current-directory stack is empty")
    local result = AliasDir.set_cwd(logical_cwd_stack[#logical_cwd_stack])
    if result == 0 then
        logical_cwd_stack[#logical_cwd_stack] = nil
    end
    return result
end

function AliasDir.reset()
    -- A new build starts from the original directory with no pending push state.
    local result = AliasDir.set_cwd(initial_cwd)
    if result == 0 then
        logical_cwd_stack = {}
    end
    return result
end

return AliasDir
