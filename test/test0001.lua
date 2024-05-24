local function dump(o)
    if type(o) == 'table' then
        local s = '{ '
        for k,v in pairs(o) do
            if type(k) ~= 'number' then k = '"'..k..'"' end
            s = s .. '['..k..'] = ' .. dump(v) .. ','
        end
        return s .. '} '
    else
        return tostring(o)
    end
end

blud              = {}
blud.public_env   = {}
blud.private_env  = { __index = blud.public_env }
blud.current_time = os.time()
-- define super atom (a metatable), which contains defaults for all atoms
blud.global = {
    BIND  = function(atom_name)
        local atom = blud.TARGETS[atom_name]
        if atom == nil then error("Unknown target: " .. atom_name) end
        atom.PARENT = nil
        return atom
    end,
    }
blud.super_atom = {
    NAME = "",
    ADD_RULE = function(target, prerequisites, action)
        print("super_atom add_rule target = " .. dump(target) .. ": " .. dump(prerequisites))
        if action ~= nil then
            if target.ACTION then
                error("Target " .. target.NAME .. " already has an action")
            else
                target.ACTION = action
            end
        end
        local existing_prerequisites = target.PREREQUISITES or {}
        for _, dep in ipairs(prerequisites) do
            table.insert(existing_prerequisites, dep)
        end
        print("    add_rule, total prereq: " .. dump(existing_prerequisites))
        target.PREREQUISITES = existing_prerequisites
    end,
    APPLY_SPECIAL = function(atom, prerequisites)
        print("APPLY_SPECIAL " .. dump(atom))
        for _, prerequisite in ipairs(prerequisites) do
            
        end
    end,
    BUILD = function(target)
        print("BUILD('" .. target.NAME .. "')")
        if target.PARENT then print("PARENT('" .. dump(target.PARENT) .. "')") end
        local timestamp = blud.get_fs_timestamp(target.NAME)
        print("timestamp is " .. timestamp)
        if timestamp < blud.current_time then
            if target.ACTION then
                print("execute: '" .. target.ACTION .. "'")
                target:DO_ACTION()
                target:AFTER_ACTION()
            end
        end
        return true   -- default is to pretend we successfully built it
    end,
    BUILD_PREREQUISITES = function(atom)
        print("BUILD_PREREQUISITES('" .. atom.NAME .. "')")
        local prerequisites = atom.PREREQUISITES;
        print("prereqs: " .. dump(prerequisites))
        if prerequisites then
            for _, prereq_name in ipairs(prerequisites) do
                prerequisite = atom.BIND(prereq_name)
--                prerequisite.PARENT = target
                prerequisite.BUILD(prerequisite, atom)
            end
        end

    end,
    DO_ACTION = function(target)
        print("DO_ACTION in super atom for " .. target.NAME)
        status, exit_code = os.execute(target.ACTION)
        assert(status)
        if exit_code then
            error("command failed: " .. target.ACTION)
        end
    end,
    AFTER_ACTION = function(target)
        return true
    end
}

setmetatable(blud.super_atom, blud.global)
blud.global.__index      = blud.global
blud.super_atom.__index  = blud.super_atom

blud.new_atom = function(atom_name)
    local atom = {}
    atom.NAME  = atom_name
    -- the initial metatable for an atom is the "super atom", which
    -- provides the default behavior
    return setmetatable(atom, blud.super_atom)
end
blud.is_special_atom = function(atom)
    return string.sub(atom.NAME, 1, 1) == "."
end

blud.set_callback = function(target, hook_name, callback_func)
    -- make new metatable whose metatable is target metatable
    local new_meta      = setmetatable({}, getmetatable(target))
    new_meta.__index    = new_meta
    -- new metatable will call callback_func for this particular hook
    new_meta[hook_name] = callback_func
    -- finally, insert new metatable before target's metatable
    setmetatable(target, new_meta)
end

blud.TARGETS = {
    [ ".AFTER" ] = {
        NAME = ".AFTER",
        ADD_RULE = function(target, prerequisites, action)
            print(".AFTER add_rule target = " .. dump(target) .. ": " .. dump(prerequisites))
            getmetatable(target).ADD_RULE(target, prerequisites, action)
            for _, dep in ipairs(target.PREREQUISITES) do
                blud.set_callback(dep, "DO_ACTION", function (target,prerequistes,action)
                    end)
            end
        end,
        DO_ACTION = function(target, prerequisites, action)
            local after = function()
                print("do after dammit!!!!!!!!!!!!!!!")
            end
print(".AFTER is setting callback")
            blud.set_callback(target.PARENT, "AFTER_ACTION", after)
            return true
        end
    }
}

for atom_name, atom in pairs(blud.TARGETS) do
    setmetatable(atom, blud.super_atom)
end

blud.get_fs_timestamp = function (filepath)
    local command = string.format("stat -c %%Y '%s' 2>/dev/null", filepath)
    local pipe = io.popen(command, "r")
    local output = pipe:read("*a")
    pipe:close()

    -- Convert the timestamp to a number
    local timestamp = tonumber(output)
    if not timestamp then
        print("Failed to get timestamp for file: " .. filepath)
        timestamp = 0
    end
    return timestamp
end

blud.add_rule = function(target, prerequisites, action)
    print("add_rule('" .. target.NAME .. "' :" .. #prerequisites .. ")")
    if action ~= nil then
        if target.ACTION then
            error("Target " .. target.NAME .. " already has an action")
        else
            target.ACTION = action
        end
    end
    local prerequisites = target.PREREQUISITES or {}
    for _, dep in ipairs(prerequisites) do
        print("    ." .. dep)
        table.insert(prerequisitess, dep)
    end
    target.PREREQUISITES = prerequisites
end

blud.add_rules = function(targets, prerequisites, action)
print("blud.add_rules targets = " .. dump(targets) .. ": " .. dump(prerequisites))
    for _, target_name in ipairs(targets) do
        local target = blud.get_or_create_target(target_name)
        print(target.NAME .. " add rule")
        target.ADD_RULE(target, prerequisites, action)
    end
end


blud.build = function(atom_name, parent_atom)
    print("[[[[[[[[[build " .. atom_name .. "]]]]]]]]")
    local target = blud.global.BIND(atom_name)
    target.PARENT = parent_atom
    target.BUILD_PREREQUISITES(target)
    return target.BUILD(target)
end

blud.get_or_create_target = function(target_name)
    print("get_or_create_target('" .. target_name .. "')")
    local target = blud.TARGETS[target_name]
    if target == nil then
        target = blud.new_atom(target_name)
        blud.TARGETS[target_name] = target
    end
    return target
end

-- build
blud.run_build = function(primary_target)
    local targets = {}
--    print("blud " .. primary_target)
    table.insert(targets, primary_target)
--    print("before for: Type of blud.build:", type(blud.build)) 
    for _, target in ipairs(targets) do
        blud.build(target, nil)
    end
end


-- test0001
--
-- Simple test to make sure SOMETHING works

do -- all:
    local targets = { "all" }
    local prerequisites = {  }
    blud.add_rules(targets, prerequisites, [[    echo "test001 worked"
    touch test0001.out
]])
end 
blud.run_build("all")

