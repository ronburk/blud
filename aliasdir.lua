--[[
AliasDir manages logical directory aliases across temporary changes to the
process current directory. It stores directory identities as absolute paths and
converts them to paths relative to the current directory when actions expand
aliases. Current path/link-boundary handling is intentionally lexical and does
not yet account for symbolic-link crossings.
]]

local AliasDir = {}

local initial_cwd = assert(os_getcwd())
local windows_paths = initial_cwd:match("^[A-Za-z]:[/\\]") or
                      initial_cwd:sub(1, 2) == "\\\\"
local current_cwd
local cwd_stack = {}

local function with_forward_slashes(path)
    return (path:gsub("\\", "/"))
end

local function split_root(path)
    local drive, remainder = path:match("^([A-Za-z]:)/(.*)$")
    if drive then
        return drive .. "/", remainder
    end

    if path:sub(1, 2) == "//" then
        local server, share, rest = path:match("^//([^/]+)/([^/]+)/*(.*)$")
        if server then
            return "//" .. server .. "/" .. share, rest
        end
    elseif path:sub(1, 1) == "/" then
        return "/", path:sub(2)
    end
end

local function append_normalized(components, path)
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

local function join_absolute(root, components)
    if #components == 0 then
        return root
    end
    local separator = root:sub(-1) == "/" and "" or "/"
    return root .. separator .. table.concat(components, "/")
end

local function absolute_parts(path)
    path = with_forward_slashes(path)
    local root, remainder = split_root(path)
    assert(root, "path is not absolute: " .. path)

    local components = {}
    append_normalized(components, remainder)
    return root, components
end

local function normalize_absolute(path)
    local root, components = absolute_parts(path)
    return join_absolute(root, components)
end

initial_cwd = normalize_absolute(initial_cwd)
current_cwd = initial_cwd

function AliasDir.get_cwd()
    return current_cwd
end

function AliasDir.to_absolute(path)
    path = with_forward_slashes(path)
    assert(path ~= "", "empty path")

    if windows_paths and path:sub(1, 1) == "/" and
       path:sub(1, 2) ~= "//" then
        local current_root = split_root(current_cwd)
        local drive = current_root:match("^([A-Za-z]:)/$")
        assert(drive, "cannot resolve a root-relative path without a drive: " .. path)
        path = drive .. path
    end

    local root = split_root(path)
    if root then
        return normalize_absolute(path)
    end

    local drive, remainder = path:match("^([A-Za-z]:)(.*)$")
    local current_root, components = absolute_parts(current_cwd)
    if drive then
        assert(current_root:sub(1, 2):lower() == drive:lower(),
               "cannot resolve a path relative to another drive: " .. path)
        path = remainder
    end

    append_normalized(components, path)
    return join_absolute(current_root, components)
end

local function path_part_equal(left, right)
    if windows_paths then
        return left:lower() == right:lower()
    end
    return left == right
end

function AliasDir.to_relative(path)
    local target_root, target_components = absolute_parts(path)
    local current_root, current_components = absolute_parts(current_cwd)
    local absolute = join_absolute(target_root, target_components)

    if not path_part_equal(target_root, current_root) then
        return absolute
    end

    local common = 0
    while current_components[common + 1] and
          target_components[common + 1] and
          path_part_equal(current_components[common + 1],
                          target_components[common + 1]) do
        common = common + 1
    end

    local relative = {}
    for _ = common + 1, #current_components do
        relative[#relative + 1] = ".."
    end
    for index = common + 1, #target_components do
        relative[#relative + 1] = target_components[index]
    end
    return #relative == 0 and "." or table.concat(relative, "/")
end

function AliasDir.set_cwd(path)
    local absolute = AliasDir.to_absolute(path)
    local result = os_setcwd(absolute)
    if result == 0 then
        current_cwd = absolute
    end
    return result
end

function AliasDir.push_cwd(path)
    local previous = current_cwd
    local result = AliasDir.set_cwd(path)
    if result == 0 then
        cwd_stack[#cwd_stack + 1] = previous
    end
    return result
end

function AliasDir.pop_cwd()
    assert(#cwd_stack > 0, "current-directory stack is empty")
    local result = AliasDir.set_cwd(cwd_stack[#cwd_stack])
    if result == 0 then
        cwd_stack[#cwd_stack] = nil
    end
    return result
end

function AliasDir.reset()
    local result = AliasDir.set_cwd(initial_cwd)
    if result == 0 then
        cwd_stack = {}
    end
    return result
end

return AliasDir
