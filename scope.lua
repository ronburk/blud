--[[
scope.lua - implement the scopes of macros/variables
--]]

local Macro = require("macro")

local Scope = {}     -- this will be the metatable for scope objects
Scope.__index = Scope


-- generic get_macro() function to return value of variable
Scope.get_macro = function(self, name)
    local result = self.variables[name]
    if result == nil and self.parent then
        result = self.parent:get_macro(name)
    end
    return result
end

-- The scope selects a macro; the macro object decides how to produce text.
-- This keeps lookup independent of the macro's backing representation.
Scope.get_text = function(self, name, ...)
    local macro = self:get_macro(name)
    return macro and macro:expand(self, { name, ... }, {}) or ""
end


-- Boolean variables use the existing textual convention:
-- empty or "false" is false; every other expanded value is true.
Scope.get_boolean = function(self, name)
    local value = self:get_text(name)
    return value ~= "" and value ~= "false"
end


-- Store a canonical textual value so normal scope inheritance and expansion apply.
Scope.set_boolean = function(self, name, value)
    assert(type(value) == "boolean")

    local parts = { value and "true" or "false" }
    self:set(name, parts)
end


-- Install an already constructed macro without invoking source-language
-- assignment. Assignment implementations use this for replacement values and
-- for private aliases that preserve an old value during self-reference.
Scope.set_macro = function(self, name, macro)
    self.variables[name] = macro
end


-- generic set() function to set value of variable
Scope.set = function(self, name, value)
    local parts

    if type(value) == "string" then
        parts = { value }
    else
        assert(type(value) == "table")
        parts = value
    end

    self:set_macro(name, Macro.from_parts(parts))
end


Scope.new = function(self, parent, name)
    local instance = {
        name       = name,
        variables  = {},
        parent     = parent,
    }
    return setmetatable(instance, Scope)
end


-- set up (most of) the scope ordering
Scope.base        = Scope:new(nil, "base")
Scope.environment = Scope:new(Scope.base, "environment")
Scope.bludfile    = Scope:new(Scope.environment, "bludfile")
Scope.commandline = Scope:new(Scope.bludfile, "commandline")
Scope.build       = Scope:new(Scope.commandline, "build")


Scope.environment.get_macro = function(self, name)
    local value = os.getenv(name)
    if value ~= nil then
        return Macro.from_parts({ value })
    end
    return self.parent:get_macro(name)
end


-- A parameter scope keeps invocation arguments local while ordinary macro
-- names continue through the scope in which the invocation occurred.
Scope.new_param_scope = function(self, actuals)
    local scope = Scope:new(self)
    scope.macro_actual = actuals
    function scope:get_macro(name)
        if name:match("^%d+$") then
            local value = self.macro_actual[tonumber(name) + 1] or ""
            return Macro.from_parts({ value })
        else
            return self.parent:get_macro(name)
        end
    end
    local function reject_assignment()
        error("You can't set a param value macro!")
    end
    scope.set = reject_assignment
    scope.set_macro = reject_assignment
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
-- deliberately reach targets through the fixed Scope.build parent scope.
Scope.new_target_scope   = function(self, target)
    local name = string.format("target(%s)", target.NAME)
    local new_scope  = Scope:new(Scope.build, name)
    new_scope.target = target
    new_scope.get_macro = target_get_macro
    return new_scope
end



return Scope
