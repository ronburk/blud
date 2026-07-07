--[[
function require_compiled(name)
    local source = CSTRGet(name)
    if source == nil then error("no such internal file: " .. name ) end
    local chunk = load(source, "internal." .. name)
    return chunk()
end
local foo = require_compiled("debugger.lua")
print(foo.dump("foo"))
assert(false)
]]

util = require("util")

blud_module_code = CSTRGet("runtime.lua")
local function dump(o)
    if type(o) == 'table' then
        local s = '{ '
        for k,v in pairs(o) do
            if type(k) ~= 'number' then k = '"'..k..'"' end
            if v ~= "__index" then
                s = s .. '['..k..'] = ' .. dump(v) .. ','
            end
        end
        return s .. '} '
    else
        return tostring(o)
    end
end


function template(str, values)
    return (str:gsub("{(.-)}", function(key)
                         return values[key] or "{" .. key .. "}"
    end))
end



blud_primary_target_name = ""


blud_user_code = ""


-- returns generator that lets you read/peek one line at a time from the file
function buffered_line_io(file)
    assert(io.type(file) == "file");
    local current_line; --  = file:read("*l")  -- Read the first line to prime the generator
    local has_peeked   = false
    local peek_line    = nil

    return function(peek)
        if peek then
            if has_peeked then
                return peek_line  -- Return the peeked line without advancing
            else
                peek_line  = file:read("*l")
                has_peeked = true
                return peek_line
            end
        else
            if has_peeked then    -- We've peeked, now consume that line
                has_peeked   = false
                current_line = peek_line
                peek_line    = nil
            else                -- No peek happened, move to the next line
                current_line = file:read("*l")
            end
            return current_line
        end
    end
end

function buffered_line_io_string(input_string)
    local lines = {}
    local pos = 1

    -- Split the input_string into lines
    for line in input_string:gmatch("([^\r\n]*)[\r\n]?") do
        table.insert(lines, line)
    end

    return function(peek)
        if pos > #lines then
            return nil -- No more lines
        end
        if peek then
            return lines[pos] -- Peek the current line without advancing
        else
            local current_line = lines[pos]
            pos = pos + 1 -- Advance to the next line
            return current_line
        end
    end
end


function calculate_indent(line)
    if line == nil then return 0 end
    local indent = 0
    for i = 1, #line do
        local char = line:sub(i, i)
        if char == ' ' then
            indent = indent + 1
        elseif char == '\t' then
            indent = indent + 4
        else
            break
        end
    end
    --    print("indent of '" .. line .. "' = " .. indent);
    return indent
end

function atoms_to_string(atoms)
    local result = ""
    for _, name in ipairs(atoms) do
        if result ~= "" then result = result .. ", " end
        result = result .. name
    end
    return result
end

do
    local keywords   = {
        ["do"]       = true,
        ["else"]     = true,
        ["elseif"]   = true,
        ["end"]      = true,
        ["for"]    = true,
        ["function"] = true,
        ["if"]       = true,
        ["local"]    = true,
        ["repeat"] = true,
        ["then"]   = true,
        ["until"]  = true,
        ["while"]  = true,
    }

    function line_is_lua(line)
        local result     = true
        local first_word = line:match("^%a+")
        if first_word ~= nil then
            if keywords[first_word] == nil then
                result = false
            end
        end
        return result
    end
end


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

function emit_macro_assign(macro_name, operator, remainder)
    local variables = {
        macro_name = lua_quote(macro_name),
        operator   = lua_quote(operator),
        remainder  = lua_quote(remainder)
    }
    local script = [[
blud.macro_assign({macro_name}, {operator}, {remainder})
]]
local var =  script:gsub("{(.-)}", variables)
print(var)
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

function preprocess(get_line)
    local previous_indent   = 0

    while true do     -- for line in file:lines() do
        local line = get_line(false)
        if line == nil then break end
        local macro_name, operator, remainder = match_macro_assign(line)
        if macro_name then
            emit_macro_assign(macro_name, operator, remainder)
        else
        end
        if false then
            if not line_is_lua(line) then
                blud_user_code = blud_user_code .. "do -- " .. line .. "\n"
                local targets, prerequisites = process_make_rule(line) 
                local indent = calculate_indent(line)
                local action = ""
                while calculate_indent(get_line(true)) > indent do
                    action = action .. get_line(false) .. "\n"
                end
                blud_user_code = blud_user_code .. "    blud.add_rules(targets, prerequisites, "
                if action == nil then
                    blud_user_code = blud_user_code .. "nil)\n"
                else
                    blud_user_code = blud_user_code .. "[[" .. action .. "]])\n"
                end
                
                blud_user_code = blud_user_code .. "end "
            else -- line is Lua, but could be extended by comment or quoted string
                while true do
                    blud_user_code = blud_user_code .. line .. '\n'
                end
            end
        end
    end
end

function process_make_rule(line)
    local targets       = {}
    local prerequisites = {}

    -- Split the line at the colon
    local target_part, prerequisite_part = line:match("^%s*(.-)%s*:%s*(.*)")

    -- Check and split the target part into paths
    blud_user_code = blud_user_code .. "    local targets = { "
    for target in target_part:gmatch("%S+") do
        blud_primary_target_name = blud_primary_target_name or target
        table.insert(targets, target)
        blud_user_code = blud_user_code .. '"' .. target .. '"'
    end
    blud_user_code = blud_user_code .. " }\n"

    -- Check and split the prerequisite part into paths
    blud_user_code = blud_user_code .. "    local prerequisites = { "
    for prerequisite in prerequisite_part:gmatch("%S+") do
        table.insert(prerequisites, prerequisite)
        blud_user_code = blud_user_code .. '"' .. prerequisite .. '"'
    end
    blud_user_code = blud_user_code .. " }\n"

    --[=[
        local code = [[    blud.add_dependents(targets, prerequisites)
        ]]

        for _, target in ipairs(targets) do
        local atom_list = ""
        for _, prerequisite in ipairs(prerequisites) do
        atom_list = atom_list .. "," .. prerequisite
        end
        code = code:gsub("{target}", target);
        code = code:gsub("{atom_list}", atom_list);
        blud_user_code = blud_user_code .. code
        end
    ]=]

    return targets, prerequisites
end



print("start executing phase 1")
local bludfile_path = get_bludfile_path()
local luac_path = bludfile_path .. ".luac"
local blud_exe_path = get_executable_path()
assert(blud_exe_path ~= nil)
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

--print(phase1_text)
local final_code = [[
blud.phase3:parse()
if blud.primary_targets == nil then
    error("No targets to build!")
else
    blud.build_init()
    for _, target in ipairs(blud.primary_targets) do
        target:BUILD()
    end
end
]]


function phase1_report_compile_error(err, code_to_compile)
    local generated_line, message = err:match(":(%d+):%s*(.*)$")
    generated_line = tonumber(generated_line)
    if not generated_line then
        error("Compilation Error: " .. err)
    end

    local lines = {}
    for line in (code_to_compile .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line)
    end

    local source_line, source_name
    for i = generated_line, 1, -1 do
        source_line, source_name =
            lines[i]:match("^--BLUDLINE%s+(%d+)%s+(.+)$")
        if source_line then
            source_line = generated_line - i
            break
        end
    end

    if source_line then
        io.stderr:write(string.format("%s:%d: %s\n",
            source_name, source_line, message))
        io.stderr:write((lines[generated_line] or "") .. "\n")
        os.exit(1)
    end

    error("Compilation Error: " .. err)
end

if luac_needs_building then
    --rlb
    local compiler = require("compiler")
    local f = nil

    f = io.open(bludfile_path)
    if f == nil then
        if not bludfile_path:lower():match("%.blud$") then
            path = bludfile_path .. ".blud"
            f = io.open(path)
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
    compile_io.push_input("bludfile", f:read("*a"))
    compile_io.emit_line("blud.bludfile_code = function()")
    compile_io.emit_sourcemap()
    compiler.compile(compile_io)
    compile_io.emit_line("end")
--    compile_io.emit_file("<blud_module_code>", blud_module_code)
    
    f:close()
--    print(blud_module_code)
    print("phase 1 complete")
    
--    print(phase1_text)

--    local code_to_compile = blud_module_code .. "\n" .. phase1_text .. "\n" .. final_code

    if not blud_primary_target_name  then
        print("No target given to build")
    else
        print("building '" ..  blud_primary_target_name .. "'")
        print( dump( blud_primary_target_name))
    end

    blud_user_code = blud_user_code .. "\nblud.run_build(\"" .. blud_primary_target_name .. "\")\n"

    -- Compile the source code to bytecode
    local code_to_compile = compile_io.close()
    if blud.command_line_options.debug == true then
        util.string_to_file("bludfile.luad", code_to_compile)
    end
    
--    print(code_to_compile)
    local compiled_function, err = loadstring(code_to_compile, "bludfile")
    
    if not compiled_function then
        phase1_report_compile_error(err, code_to_compile)
    end

    local bytecode = string.dump(compiled_function, false) -- true to strip debugging info

    -- Save the bytecode to a file
    local luac_path = bludfile_path .. ".luac"
    local file = io.open(luac_path, "wb")
    if file then
        file:write(bytecode)
        file:close()
        print("Bytecode saved to " .. luac_path)
    else
        print("Failed to open file for writing")
    end
else
    print("using pre-compiled bludfile!")
    error("done")
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


local function split_lua_runtime_error(err)
    local chunk_name, generated_ln, message =
        text:match('^%[string "([^"]*)"%]:(%d+):%s*(.*)$')

    assert(
        chunk_name,
        "\nCould not parse Lua runtime error message" ..
        "\nexpected form: [string \"...\"]:line: message" ..
        "\nactual:        " .. string.format("%q", err)
    )

    generated_ln = tonumber(generated_ln)

    assert(generated_ln)
    assert(message)

    return chunk_name, generated_ln, message
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
print("now run user code")
blud.bludfile_code()
if blud.command_line_options.target_names then
    blud.primary_targets = {}
    for _, name in ipairs(blud.command_line_options.target_names) do
        table.insert(blud.primary_targets, blud.get_or_create_target(name))
    end
end
util.print("----------\n%d rules", #blud.rules)
for i=1,#blud.rules do
    util.print("[%d] %s", i, util.dump(blud.rules[i]))
end

util.print("OK, now ready to update: %s", util.dump(blud.primary_targets))
print(type(blud.primary_targets), #blud.primary_targets)
if blud.primary_targets == nil then
    error("no targets to build")
end
blud.build_init()
-- util.print("%d targets %s", #blud.primary_targets, util.dump(blud.primary_targets))
util.print("%d targets", #blud.primary_targets)
for _,target in ipairs(blud.primary_targets) do
--    util.print("build target '%s'", util.dump(target))
    util.print("build target '%s'", target.NAME)
    target:BUILD()
end


--[[
print("About to call pcall")
local ok, err = pcall(execute_bytecode, (luac_path))
print(string.format("After pcall, ok=%q, err=%q", ok, err))
if not ok then
    print("Got an error in our compiled bludfile at runtime")
    assert(blud.sourcemap)
    if blud.sourcemap then
        blud.report_runtime_error(err, blud.sourcemap)
    else
        print("Error executing bytecode: " .. tostring(err))
    end
end
--]]



--print(blud_user_code);

--[[
    function lines_length(input, line_number)
    if line_number >= 1 then
    local current_line = 1
    local position = 1

    -- Repeat finding new lines until the desired line
    while true do
    if current_line == line_number then
    return position
    end
    local start_pos, end_pos = string.find(input, "\n", position)
    if not start_pos then
    break  -- No more newlines found
    end
    current_line = current_line + 1
    position     = end_pos + 1
    end
    end
    return nil  -- Line number does not exist in the input
    end


    function parse_blud_file_text(source_text)
    local lua_text  = ""
    local func, error_message = loadstring(source_text)
    local line, message = error_message:match(":(%d+):%s*(.*)")
    if error_message then
    print("line " .. line .. ": " .. message)
    assert(false)
    end
    end
    parse_blud_file_text(blud_file_text)
    assert(false)
]]

--[[
    function report_error(error_message, code)
    print("Error ", error_message)
    -- Extracting the line number from the error message
    local lineNumber = tonumber(error_message:match(":(%d+):"))
    if lineNumber then
    -- Splitting the code into lines and printing the problematic line
    local lines = {}
    for line in code:gmatch("([^\n]*)\n?") do
    table.insert(lines, line)
    end
    print("Error at line", lineNumber, ":", lines[lineNumber])
    end

    end


    local program = blud_module_code .. blud_user_code
    local func, err = loadstring(program)
    print("back from loadstring")
    if func then
    status, err = pcall(func)
    if not status then
    report_error(err, program);
    end
    else
    report_error(err, program);
    end
]]

