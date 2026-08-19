
util = require("util")

blud_module_code = CSTRGet("runtime.lua")



blud_primary_target_name = ""


blud_user_code = ""



function lua_quote(str)
    -- Escape backslashes and double quotes
    str = str:gsub("\\", "\\\\"):gsub('"', '\\"')
    
    -- Replace special characters
    str = str:gsub("\n", "\\n")
        :gsub("\r", "\\r")
        :gsub("\t", "\\t")
        :gsub("\b", "\\b")
        :gsub("\f", "\\f")
    
    -- Wrap the string in double quotes
    return '"' .. str .. '"'
end


function syntax_error(line, line_number, format_string, ...)
    io.stderr:write(line)
    io.stderr:write("\n^^^^\n")
    io.stderr:write(string.format("Error on line %d: ", line_number))
    if format_string then
        local args = {...}
        local message = format_string:gsub("#(%d+)", function(n)
                                               return tostring(args[tonumber(n)])
        end)
        io.stderr:write(message)
    end
    io.stderr:write("\n")
    os.exit(1)
end

-- handle a Lua line that might have embedded make code
-- ??? does not handle embedded $(name a b "c" "d()")
function phase1_embedded_make(line)
    local code = line:match("^%s*$ (.*)$")
    if code then
        line = "blud.phase2_append(" .. lua_quote(code) .. ")"
    end
    return line
end

function phase1_line_is_empty(line)
    if line:find("^%s*$") then
        return true
    elseif line:find("^%s*%-%-[^[]") then
        return true
    elseif line:find("^%s*%-%-") then
        return true
    else
        return false
    end
end



local bludfile_path = get_bludfile_path()
local luac_path     = bludfile_path .. ".luac"
local blud_exe_path = get_executable_path()
local blud_exe_timestamp = get_path_timestamp(blud_exe_path)
local bludfile_timestamp = get_path_timestamp(bludfile_path)
local luac_timestamp     = get_path_timestamp(luac_path)

local luac_needs_building = true
if bludfile_timestamp ~= nil and luac_timestamp ~= nil then
    if blud_exe_timestamp < bludfile_timestamp and blud_exe_timestamp < luac_timestamp then
        if bludfile_timestamp < luac_timestamp then
            luac_needs_building = false
        end
    end
end


if luac_needs_building then
    --rlb
    local compiler = require("compiler")
    local f = nil
    local source_path = bludfile_path

    f = io.open(source_path)
    if f == nil then
        if not bludfile_path:lower():match("%.blud$") then
            source_path = bludfile_path .. ".blud"
            f = io.open(source_path)
        end
        if f == nil then
            error("Could not open: " .. bludfile_path)
        end
    end

    --file = io.stdin
    --preprocess(buffered_line_io(file))
--    local phase1_text = phase1_pass("[buildin.blud]",
--                                    buffered_line_io_string(CSTRGet("builtin.blud")))
--    phase1_text = phase1_text .. phase1_pass("bludfile", buffered_line_io(file))

    local compile_io = require("compile_io")
    local chunk, err   = loadstring(blud_module_code, "<runtime>")
    if not chunk then error (err) end
    local runtime = string.format("loadstring(%s,\"<runtime>\")()\n",
                                  util.chunk_to_lua(chunk))
    compile_io.emit_file("<runtime>", runtime)

    compile_io.push_input("builtin.blud", CSTRGet("builtin.blud"))
    compiler.compile(compile_io)
    compile_io.push_input(source_path, f:read("*a"))
    compile_io.emit_line("blud.bludfile_code = function()")
    compile_io.emit_sourcemap()
    compiler.compile(compile_io)
    compile_io.emit_line("end")
--    compile_io.emit_file("<blud_module_code>", blud_module_code)
    
    f:close()
--    print(blud_module_code)
    -- print("phase 1 complete")
    
--    print(phase1_text)

--    local code_to_compile = blud_module_code .. "\n" .. phase1_text .. "\n" .. final_code

    if not blud_primary_target_name  then
        print("No target given to build")
    else
        -- print("building '" ..  blud_primary_target_name .. "'")
        -- print( dump( blud_primary_target_name))
    end

    blud_user_code = blud_user_code .. "\nblud.run_build(\"" .. blud_primary_target_name .. "\")\n"

    -- Compile the source code to bytecode
    local code_to_compile, sourcemap = compile_io.close()
    if blud.command_line_options.debug == true then
        util.string_to_file("bludfile.luad", code_to_compile)
    end
    
--    print(code_to_compile)
    local compiled_function, err =
        blud.load_lua_source(code_to_compile, source_path, sourcemap)
    
    if not compiled_function then
        error("Compilation Error: " .. err, 0)
    end

    local bytecode = string.dump(compiled_function, false) -- true to strip debugging info

    -- Save the bytecode to a file
    local luac_path = bludfile_path .. ".luac"
    local file = io.open(luac_path, "wb")
    if file then
        file:write(bytecode)
        file:close()
        -- print("Bytecode saved to " .. luac_path)
    else
        print("Failed to open file for writing")
    end
end

local function source_from_generated_line(map, generated_ln)
    for i = #map, 1, -1 do
        local entry = map[i]
        if generated_ln >= entry.dest_ln then
            return entry.filename, entry.source_ln + generated_ln - entry.dest_ln
        end
    end
end

function blud.report_runtime_error(err, map)
    local chunk_name, generated_ln, message =
        tostring(err):match('^%[string "([^"]*)"%]:(%d+):%s*(.*)$')

    if not generated_ln then
        print("Error executing bytecode: " .. tostring(err))
        return
    end

    generated_ln = tonumber(generated_ln)

    local filename, source_ln = source_from_generated_line(map, generated_ln)
    if not filename then
        print("Error executing bytecode: " .. tostring(err))
        return
    end

    print(string.format(
        "%s:%d: %s",
        filename,
        source_ln,
        message
    ))
end


-- execute the bytecode residing in an external file
function execute_bytecode(file_path)
    -- Open the bytecode file
    local file, err = io.open(file_path, "rb")
    if not file then
        print("Failed to open file: " .. err)
        return
    end

    -- Read the bytecode
    local bytecode = file:read("*all")
    file:close()

    -- Load the bytecode
    local func, load_err = load(bytecode)
    if not func then
        print("Failed to load bytecode: " .. load_err)
        return
    end

    blud.sourcemap_chunk_name = debug.getinfo(func, "S").source
    func()
return
--[[
    -- Execute the bytecode and trap errors
    local status, exec_err = pcall(func)
    if not status then
        if not blud.sourcemap then
            print("sourcemap not found, line numbers may be wrong.")
        end
        print("Error executing bytecode: " .. exec_err)
        blud.report_runtime_error(exec_err, blud.sourcemap)
    end
--]]
end

execute_bytecode(luac_path)
-- print("now run user code")
blud.bludfile_code()
if blud.command_line_options.assume_new_names then
    for _, name in ipairs(blud.command_line_options.assume_new_names) do
        local atom = blud.get_or_create_target(name)
        atom.SCOPE:set_boolean(".ASSUME_NEW", true)
    end
end
if blud.command_line_options.target_names then
    blud.primary_targets = {}
    for _, name in ipairs(blud.command_line_options.target_names) do
        table.insert(blud.primary_targets, blud.get_or_create_target(name))
    end
elseif blud.default_target then
    blud.primary_targets = { blud.default_target }
end
-- util.print("----------\n%d rules", #blud.rules)
for i=1,#blud.rules do
    -- util.print("[%d] %s", i, util.dump(blud.rules[i]))
end

-- util.print("OK, now ready to update: %s", util.dump(blud.primary_targets))
-- print(type(blud.primary_targets), #blud.primary_targets)
if blud.primary_targets == nil then
    error("no targets to build")
end
blud.build_init()
blud.debugger.probe({func="<update>"})
-- util.print("%d targets %s", #blud.primary_targets, util.dump(blud.primary_targets))
-- util.print("%d targets", #blud.primary_targets)
blud.build_targets(blud.primary_targets)
blud.why.report()


