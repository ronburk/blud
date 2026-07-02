--[[
scope.lua - implement the scopes of macros/variables
--]]

local M = {}     -- this will be the metatable for scope objects
M.__index = M


-- generic get() function to return value of variable
M.get = function(self, name)
    local result = self.variables[name]
    if result == nil and self.parent then
        result = self.parent:get(name)
    end
    return result
end

-- generic get_text() function, wraps get() and handles expanding variable definition into text
M.get_text = function(self, name)
    local tokens = self:get(name)
    local result = ""
    if tokens then
        result = blud.Macro.expand_tokens(self, tokens)
    end
    return result
end


-- generic set() function to set value of variable
M.set = function(self, name, value)
    self.variables[name] = value
end


M.new = function(self, parent, name)
    local instance = {
        name       = name,
        variables  = {},
        parent     = parent,
    }
    return setmetatable(instance, M)
end


-- set up (most of) the scope ordering
M.base        = M:new(nil, "base")
M.environment = M:new(M.base, "environment")
M.bludfile    = M:new(M.environment, "bludfile")
M.commandline = M:new(M.bludfile, "commandline")
M.build       = M:new(M.commandline, "build")


M.environment.get = function(self, name)
    local value = os.getenv(name)
    if value ~= nil then
        return { value }
    end
    return self.parent:get(name)
end


-- a param scope filters out any numeric macro name references
-- it never allows those references to search any higher scope
-- it passes all non-numeric macro name references up the scope chain
M.new_param_scope = function(self, parent, macro_actual)
    local scope = M:new(parent)
    scope.macro_actual = macro_actual
    function scope:get(name)
        blud.assert(name)
        if name:match("^%-?%d+$") then
            blud.error(" don't handle numerics yet!")
        else
            return self.parent:get(name)
        end
    end
    function scope:set(name, value)
        error("You can't set a param value macro!")
    end
    return scope
end

local function target_get(self, name)
    local result
    local bound_name = ""
    if name == "<" then
        local first_prereq = self.target.PREREQUISITES[1]
        if first_prereq then
            result =  first_prereq.BOUND_NAME
        end
    elseif name == "^" then
        result = {}
        local seen = {}
        for _, prereq in ipairs(self.target.PREREQUISITES) do
            local bound_name = prereq.BOUND_NAME
            if not seen[bound_name] then
                seen[bound_name] = true
                table.insert(result, prereq.BOUND_NAME)
                table.insert(result,  " " )
            end
        end
        result = table.concat(result)
    elseif name == "@" then
        result = self.target.BOUND_NAME
    else
        result = self.variables[name]
        if result == nil and self.parent then
            result = self.parent:get(name)
        end
    end
    return result
end

-- create a new per-target scope

-- we always use M.build for the parent scope; at runtime,
-- all but the first build target will have to adjust their
-- parent pointer
M.new_target_scope   = function(self, target)
    local name = string.format("target(%s)", target.NAME)
    local new_scope  = M:new(M.build, name)
    new_scope.target = target
    new_scope.get    = target_get
    return new_scope
end



return M
