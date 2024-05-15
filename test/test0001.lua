blud              = {}
blud.public_env   = {}
blud.private_env  = { __index = blud.public_env }
blud.current_time = os.time()
blud.TARGETS = {}
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

blud.add_rule = function(targets, prerequisites, action)
    for _, target_name in ipairs(targets) do
        local target = blud.TARGETS[target_name]
        if target == nil then
            target = {}
            blud.TARGETS[target_name] = target
        end
        if action ~= nil then
            if target.ACTION then
                error("Target " .. target_name .. " already has an action")
            else
                target.ACTION = action
            end
        end
        local prerequisites = target.PREREQUISITES or {}
        for _, dep in ipairs(prerequisites) do
            table.insert(prerequisitess, dep)
        end
        target.PREREQUISITES = prerequisites
    end
end
blud.build = function(atom_name)
    print("build " .. atom_name)
    local atom = blud.TARGETS[atom_name]
    if atom == nil then error("Unknown target: " .. atom_name) end
    local prerequisites = atom.prerequisites;
    if prerequisites then
        for _, prerequisite in ipairs(prerequisites) do
            bind.build(prerequisite)
        end
    end

    local timestamp = blud.get_fs_timestamp(atom_name)
    print("timestamp is " .. timestamp)
    if timestamp < blud.current_time then
--        print(" execute action " .. atom.ACTION)
        if atom.ACTION then
print("execute: '" .. atom.ACTION .. "'")
            status, exit_code = os.execute(atom.ACTION)
            assert(status)
            if exit_code then
                error("command failed: " .. atom.ACTION)
            end
        end
    end
end
blud.run_build = function(primary_target)
    local targets = {}
--    print("blud " .. primary_target)
    table.insert(targets, primary_target)
--    print("before for: Type of blud.build:", type(blud.build)) 
    for _, target in ipairs(targets) do
        blud.build(target)
    end
end

-- test0001
--
-- Simple test to make sure SOMETHING works

do -- all:
    local targets = { "all" }
    local prerequisites = {  }
    blud.add_rule(targets, prerequisites, [[    echo "test001 worked"
    touch test0001.out
]])
end 
blud.run_build("all")

