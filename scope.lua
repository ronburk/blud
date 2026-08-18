--[[
scope.lua - implement the scopes of macros/variables
--]]

local Macro = require("macro")

local M = {}     -- this will be the metatable for scope objects
M.__index = M


-- generic get_macro() function to return value of variable
M.get_macro = function(self, name)
    local result = self.variables[name]
    if result == nil and self.parent then
        result = self.parent:get_macro(name)
    end
    return result
end

-- generic get_text() function, wraps get_macro() and handles expanding variable definition into text
M.get_text = function(self, name)
    local macro = self:get_macro(name)
    local result = ""
    if macro then
        result = blud.Macro.expand_tokens(self, macro:get_parts())
    end
    return result
end


-- Boolean variables use the existing textual convention:
-- empty or "false" is false; every other expanded value is true.
M.get_boolean = function(self, name)
    local value = self:get_text(name)
    return value ~= "" and value ~= "false"
end


-- Store a canonical textual value so normal scope inheritance and expansion apply.
M.set_boolean = function(self, name, value)
    assert(type(value) == "boolean")

    local parts = { value and "true" or "false" }
    self:set(name, parts)
end


-- generic set() function to set value of variable
M.set = function(self, name, value)
    local parts

    if type(value) == "string" then
        parts = { value }
    else
        assert(type(value) == "table")
        parts = value
    end

    self.variables[name] = Macro.from_parts(parts)
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


M.environment.get_macro = function(self, name)
    local value = os.getenv(name)
    if value ~= nil then
        return Macro.from_parts({ value })
    end
    return self.parent:get_macro(name)
end


-- a param scope filters out any numeric macro name references
-- it never allows those references to search any higher scope
-- it passes all non-numeric macro name references up the scope chain
M.new_param_scope = function(self, parent, macro_actual)
    local scope = M:new(parent)
    scope.macro_actual = macro_actual
    function scope:get_macro(name)
        if name:match("^%-?%d+$") then
            blud.error(" don't handle numerics yet!")
        else
            return self.parent:get_macro(name)
        end
    end
    function scope:set(name, value)
        error("You can't set a param value macro!")
    end
    return scope
end

local function target_get_macro(self, name)
    local result
    local bound_name = ""
    if name == "<" then
        local first_prereq = self.target.PREREQUISITES[1]
        if first_prereq then
            result = Macro.from_parts({ first_prereq.BOUND_NAME })
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
        result = Macro.from_parts({ table.concat(result) })
    elseif name == "@" then
        result = Macro.from_parts({ self.target.BOUND_NAME })
    else
        result = self.variables[name]
        if result == nil and self.parent then
            result = self.parent:get_macro(name)
        end
    end
    return result
end

-- create a new per-target scope

-- Target-specific values apply only to this target. Build-wide values
-- deliberately reach targets through the fixed M.build parent scope.
M.new_target_scope   = function(self, target)
    local name = string.format("target(%s)", target.NAME)
    local new_scope  = M:new(M.build, name)
    new_scope.target = target
    new_scope.get_macro = target_get_macro
    return new_scope
end



return M
