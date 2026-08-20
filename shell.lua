-- Parse and execute recognized commands using blud's portable command grammar.
-- Unrecognized commands retain their original text and run through the
-- operating-system shell.
local AliasDir = require("aliasdir")
local M = {}

-- Print a command-style diagnostic and return the conventional failure status.
local function diagnostic(command, message)
    io.stderr:write(command, ": ", message, "\n")
    return 1
end

-- Split one command line into words. Spaces and tabs delimit words; single and
-- double quotes group text; backslash quotes the following character. Unquoted
-- shell operators and substitutions are rejected because blud does not define
-- them. Each word records whether it contains an unquoted glob metacharacter.
local function parse(command)
    local words = {}
    local bytes = {}
    local word_started = false
    local has_glob = false
    local command_name
    local quote
    local pos = 1

    local function append(c, glob)
        bytes[#bytes + 1] = c
        word_started = true
        has_glob = has_glob or glob
    end

    local function finish_word()
        if word_started then
            words[#words + 1] = {
                text = table.concat(bytes),
                glob = has_glob,
            }
            command_name = command_name or words[#words].text
            bytes = {}
            word_started = false
            has_glob = false
        end
    end

    while pos <= #command do
        local c = command:sub(pos, pos)

        if quote == "'" then
            if c == "'" then
                quote = nil
            else
                append(c, false)
            end
        elseif quote == '"' then
            if c == '"' then
                quote = nil
            elseif c == "$" or c == "`" then
                return nil, "unsupported syntax '" .. c .. "'", command_name
            elseif c == "\\" then
                local next_c = command:sub(pos + 1, pos + 1)
                if next_c == "" then
                    append("\\", false)
                elseif next_c == '"' or next_c == "\\" or
                       next_c == "$" or next_c == "`" then
                    append(next_c, false)
                    pos = pos + 1
                else
                    append("\\", false)
                end
            else
                append(c, false)
            end
        elseif c == " " or c == "\t" then
            finish_word()
        elseif c == "'" or c == '"' then
            quote = c
            word_started = true
        elseif c == "\\" then
            local next_c = command:sub(pos + 1, pos + 1)
            if next_c == "" then
                append("\\", false)
            else
                append(next_c, false)
                pos = pos + 1
            end
        elseif c == "#" and not word_started then
            break
        elseif c == "$" or c == "`" or c == "|" or c == "&" or
               c == ";" or c == "<" or c == ">" or c == "(" or
               c == ")" or c == "{" or c == "}" or
               (c == "~" and not word_started) then
            local parsed_command_name = command_name
            if not parsed_command_name and word_started and
               (c == "|" or c == "&" or c == ";" or
                c == "<" or c == ">") then
                parsed_command_name = table.concat(bytes)
            end
            return nil,
                   "unsupported syntax '" .. c .. "'",
                   parsed_command_name
        else
            append(c, c == "*" or c == "?" or c == "[")
        end

        pos = pos + 1
    end

    if quote then
        return nil, "unterminated quote", command_name
    end

    finish_word()
    return words
end

-- Convert parsed words to argv and expand only unquoted glob metacharacters.
-- As in default Bash behavior, an unmatched pattern remains a literal operand.
local function expand_words(words)
    local argv = {}
    for _, word in ipairs(words) do
        if word.glob and blud and blud.glob then
            local count = blud.glob.expand_pattern(argv, word.text)
            if count == 0 then
                argv[#argv + 1] = word.text
            end
        else
            argv[#argv + 1] = word.text
        end
    end

    return argv
end

-- Recognize a literal first word `shell` and return everything after its first
-- separating space or tab unchanged. Quoting, substitutions, operators, and
-- additional whitespace in that remainder therefore reach the OS shell verbatim.
local function extract_shell_text(command)
    local first = command:find("[^ \t]")
    if not first or command:sub(first, first + 4) ~= "shell" then
        return nil
    end

    local after = first + 5
    if after > #command then
        return ""
    end

    local separator = command:sub(after, after)
    if separator ~= " " and separator ~= "\t" then
        return nil
    end

    return command:sub(after + 1)
end

-- Implement `shell text...`. Lua calls this as `shell(text)`, where text is the
-- exact remainder of the original line rather than a parsed argv array.
local function shell(text)
    if text == "" then
        return 0
    end
    return os.execute(text)
end

-- Implement `cp [-r|-R] [--] source destination`. argv[1] is "cp".
local function cp(argv)
    local recursive = false
    local paths = {}
    local options = true

    for i = 2, #argv do
        local arg = argv[i]
        if options and arg == "--" then
            options = false
        elseif options and (arg == "-r" or arg == "-R") then
            recursive = true
        elseif options and arg:sub(1, 1) == "-" and arg ~= "-" then
            return diagnostic("cp", "unsupported option '" .. arg .. "'")
        else
            options = false
            paths[#paths + 1] = arg
        end
    end

    if #paths == 0 then
        return diagnostic("cp", "missing file operand")
    elseif #paths == 1 then
        return diagnostic("cp", "missing destination operand")
    elseif #paths > 2 then
        return diagnostic("cp", "too many operands")
    end

    local source_type = os_path_type(paths[1])
    local result
    if source_type == 2 then
        if not recursive then
            return diagnostic("cp", "cannot copy directory '" .. paths[1] .. "' without -r")
        end
        result = os_copy_dir(paths[1], paths[2])
    else
        result = os_copy_file(paths[1], paths[2])
    end

    if result ~= 0 then
        return diagnostic("cp", "cannot copy '" .. paths[1] .. "' to '" .. paths[2] .. "'")
    end

    return 0
end

-- Implement `touch [-c|--no-create] [--] path...`. argv[1] is "touch";
-- return 0 on success and 1 after emitting the first diagnostic.
local function touch(argv)
    local no_create = false
    local paths = {}
    local options = true

    for i = 2, #argv do
        local arg = argv[i]
        if options and arg == "--" then
            options = false
        elseif options and (arg == "-c" or arg == "--no-create") then
            no_create = true
        elseif options and arg:sub(1, 1) == "-" and arg ~= "-" then
            return diagnostic("touch", "unsupported option '" .. arg .. "'")
        else
            options = false
            paths[#paths + 1] = arg
        end
    end

    if #paths == 0 then
        return diagnostic("touch", "missing file operand")
    end

    for _, path in ipairs(paths) do
        if not no_create or os_path_type(path) ~= 0 then
            if os_touch(path) ~= 0 then
                return diagnostic("touch", "cannot touch '" .. path .. "'")
            end
        end
    end

    return 0
end

-- Escape sequences accepted by Bash echo when -e is active. Numeric escapes
-- are handled separately because they consume a variable number of digits.
local echo_escapes = {
    a = "\a",
    b = "\b",
    e = string.char(27),
    E = string.char(27),
    f = "\f",
    n = "\n",
    r = "\r",
    t = "\t",
    v = "\v",
    ["\\"] = "\\",
}

-- Expand one echo operand. The second result reports \c, which suppresses all
-- remaining output as well as the trailing newline.
local function expand_echo_escapes(text)
    local output = {}
    local pos = 1

    while pos <= #text do
        local c = text:sub(pos, pos)
        if c ~= "\\" or pos == #text then
            output[#output + 1] = c
        else
            local next_c = text:sub(pos + 1, pos + 1)
            if next_c == "c" then
                return table.concat(output), true
            elseif echo_escapes[next_c] then
                output[#output + 1] = echo_escapes[next_c]
                pos = pos + 1
            elseif next_c == "0" then
                local digits = text:match("^([0-7][0-7]?[0-7]?)", pos + 2) or ""
                if digits ~= "" then
                    output[#output + 1] = string.char(tonumber(digits, 8))
                    pos = pos + 1 + #digits
                else
                    output[#output + 1] = "\\0"
                    pos = pos + 1
                end
            elseif next_c == "x" then
                local digits = text:match("^([%da-fA-F][%da-fA-F]?)", pos + 2) or ""
                if digits ~= "" then
                    output[#output + 1] = string.char(tonumber(digits, 16))
                    pos = pos + 1 + #digits
                else
                    output[#output + 1] = "\\x"
                    pos = pos + 1
                end
            else
                output[#output + 1] = "\\"
                output[#output + 1] = next_c
                pos = pos + 1
            end
        end
        pos = pos + 1
    end

    return table.concat(output), false
end

-- Implement `echo [-n] [-e|-E]... [arg...]`. argv[1] is "echo" and
-- the function returns a shell status. Adjacent recognized option groups follow
-- Bash behavior, with the last -e or -E controlling escape interpretation.
local function echo(argv)
    local newline = true
    local escapes = false
    local first = 2

    while first <= #argv and argv[first]:match("^%-[neE]+$") do
        for option in argv[first]:gmatch("[neE]") do
            if option == "n" then
                newline = false
            elseif option == "e" then
                escapes = true
            else
                escapes = false
            end
        end
        first = first + 1
    end

    local output = {}
    local stop = false
    for i = first, #argv do
        local text = argv[i]
        if escapes then
            text, stop = expand_echo_escapes(text)
        end
        output[#output + 1] = text
        if stop then
            newline = false
            break
        end
    end

    io.stdout:write(table.concat(output, " "))
    if newline then
        io.stdout:write("\n")
    end
    return 0
end

-- Join a directory and child name without duplicating an existing separator.
-- Forward slash is accepted by both supported operating systems.
local function join_path(parent, name)
    local last = parent:sub(-1)
    if last == "/" or last == "\\" then
        return parent .. name
    end
    return parent .. "/" .. name
end

-- Remove one already-expanded operand. Directories recurse through the same
-- directory cache used by globbing; symlinks/reparse points are treated as files
-- by os_path_type() so recursion does not cross them.
local function remove_path(path, recursive, force)
    local path_type = os_path_type(path)
    if path_type == 0 then
        if force then
            return 0
        end
        return diagnostic("rm", "cannot remove '" .. path .. "': No such file or directory")
    end

    if path_type == 2 then
        if not recursive then
            return diagnostic("rm", "cannot remove '" .. path .. "': Is a directory")
        end

        local entries = get_dir_cache(path)
        for name, entry in pairs(entries) do
            if name ~= "." and type(entry) == "table" then
                local status = remove_path(join_path(path, name), true, force)
                if status ~= 0 then
                    return status
                end
            end
        end

        if os_remove_dir(path) ~= 0 then
            return diagnostic("rm", "cannot remove directory '" .. path .. "'")
        end
    elseif os_remove_file(path) ~= 0 then
        return diagnostic("rm", "cannot remove '" .. path .. "'")
    end

    return 0
end

-- Implement `rm [-f] [-r|-R] [--] path...`. argv[1] is "rm";
-- stop at the first failure and return the corresponding shell status.
local function rm(argv)
    local recursive = false
    local force = false
    local paths = {}
    local options = true

    for i = 2, #argv do
        local arg = argv[i]
        if options and arg == "--" then
            options = false
        elseif options and arg:sub(1, 1) == "-" and arg ~= "-" then
            for option in arg:sub(2):gmatch(".") do
                if option == "f" then
                    force = true
                elseif option == "r" or option == "R" then
                    recursive = true
                else
                    return diagnostic("rm", "unsupported option '-" .. option .. "'")
                end
            end
        else
            options = false
            paths[#paths + 1] = arg
        end
    end

    if #paths == 0 then
        if force then
            return 0
        end
        return diagnostic("rm", "missing operand")
    end

    for _, path in ipairs(paths) do
        local status = remove_path(path, recursive, force)
        if status ~= 0 then
            return status
        end
    end

    return 0
end

-- Implement `mkdir [-p] [--] path...`. argv[1] is "mkdir". Plain mkdir
-- uses os_mkdir_one() so a missing parent or existing destination is an error;
-- -p uses the older recursive os_mkdir() and accepts existing directories.
local function mkdir(argv)
    local parents = false
    local paths = {}
    local options = true

    for i = 2, #argv do
        local arg = argv[i]
        if options and arg == "--" then
            options = false
        elseif options and arg:sub(1, 1) == "-" and arg ~= "-" then
            for option in arg:sub(2):gmatch(".") do
                if option == "p" then
                    parents = true
                else
                    return diagnostic("mkdir", "unsupported option '-" .. option .. "'")
                end
            end
        else
            options = false
            paths[#paths + 1] = arg
        end
    end

    if #paths == 0 then
        return diagnostic("mkdir", "missing operand")
    end

    for _, path in ipairs(paths) do
        local result
        if parents then
            result = os_mkdir(path)
            if result == 2 then
                return diagnostic("mkdir", "cannot create directory '" .. path .. "'")
            end
        else
            result = os_mkdir_one(path)
            if result == 1 then
                return diagnostic("mkdir", "cannot create directory '" .. path .. "': File exists")
            elseif result == 2 then
                return diagnostic("mkdir", "cannot create directory '" .. path .. "'")
            end
        end
    end

    return 0
end

-- Implement `cd [--] [directory|-]`. argv[1] is "cd". This changes the
-- blud process directory, intentionally preserving the effect for later actions,
-- and keeps private OLDPWD-like state for `cd -`.
local function cd(argv)
    local first = 2
    if argv[first] == "--" then
        first = first + 1
    elseif argv[first] and argv[first]:sub(1, 1) == "-" and argv[first] ~= "-" then
        return diagnostic("cd", "unsupported option '" .. argv[first] .. "'")
    end

    if first < #argv then
        return diagnostic("cd", "too many arguments")
    end

    local old_directory = AliasDir.get_cwd()

    local path = argv[first]
    local print_directory = false
    if not path then
        path = os.getenv("HOME") or os.getenv("USERPROFILE")
        if not path then
            return diagnostic("cd", "HOME not set")
        end
    elseif path == "-" then
        path = M.previous_directory
        if not path then
            return diagnostic("cd", "OLDPWD not set")
        end
        print_directory = true
    end

    if AliasDir.set_cwd(path) ~= 0 then
        return diagnostic("cd", path .. ": No such file or directory")
    end

    M.previous_directory = old_directory
    if print_directory then
        io.stdout:write(AliasDir.get_cwd(), "\n")
    end
    return 0
end

-- Return text selected by the first boundary. Text following the boundary on
-- that line is a complete one-line script. Otherwise, the text before the
-- boundary is a prefix that must begin every enclosed line and is stripped
-- until a closing boundary.
local function extract_source_script(text, boundary)
    local pos = 1
    local line_number = 1
    local prefix

    while pos <= #text do
        local newline = text:find("\n", pos, true)
        local next_pos = newline and newline + 1 or #text + 1
        local line = text:sub(pos, newline or #text)
        local boundary_pos = line:find(boundary, 1, true)

        if boundary_pos then
            prefix = line:sub(1, boundary_pos - 1)
            local inline_script = line:sub(boundary_pos + #boundary)
            if inline_script:find("%S") then
                inline_script = inline_script:gsub("^%s+", "")
                return string.rep("\n", line_number - 1) .. inline_script
            end
            pos = next_pos
            line_number = line_number + 1
            break
        end

        pos = next_pos
        line_number = line_number + 1
    end

    if not prefix then
        return nil, "opening boundary " .. string.format("%q", boundary) .. " not found"
    end

    -- Keep extracted lines at their physical file line numbers. The stripped
    -- text is also retained in the sourcemap, so padding keeps displayed lines
    -- aligned without retaining text outside the selected boundary.
    local script = {string.rep("\n", line_number - 1)}
    while pos <= #text do
        local newline = text:find("\n", pos, true)
        local next_pos = newline and newline + 1 or #text + 1
        local line = text:sub(pos, newline or #text)

        if line:sub(1, #prefix) ~= prefix then
            return nil, "line " .. line_number .. " does not begin with prefix " ..
                string.format("%q", prefix)
        end

        local stripped = line:sub(#prefix + 1)
        if stripped:sub(1, #boundary) == boundary then
            return table.concat(script)
        end

        script[#script + 1] = stripped
        pos = next_pos
        line_number = line_number + 1
    end

    return nil, "closing boundary " .. string.format("%q", boundary) .. " not found"
end

local source_chunk_number = 0

local function compile_source_action(filename, script)
    local compiler = require("compiler")
    local compile_io = require("compile_io")

    compile_io.push_input(filename, script)
    compile_io.emit_sourcemap()
    compiler.compile_action(compile_io)
    local generated, sourcemap = compile_io.close(false)

    source_chunk_number = source_chunk_number + 1
    local chunk_name = string.format(
        "[source %d: %s]", source_chunk_number, filename)
    local chunk, load_error = blud.load_lua_source(
        generated, chunk_name, sourcemap)
    if not chunk then
        error("Compilation Error: " .. load_error, 0)
    end

    local action = chunk()
    assert(type(action) == "function",
           "compiled source did not produce an action")
    return action
end

-- Implement `source [--boundary string] [--] file`, accepting options before
-- or after the file, by compiling the selected text as an action body and
-- executing it in the caller's scope.
local function source(argv, scope)
    local boundary
    local filename
    local options = true
    local pos = 2

    while pos <= #argv do
        local arg = argv[pos]
        if options and arg == "--" then
            options = false
        elseif options and arg == "--boundary" then
            pos = pos + 1
            boundary = argv[pos]
            if not boundary then
                return diagnostic("source", "option '--boundary' requires an argument")
            elseif boundary == "" then
                return diagnostic("source", "boundary must not be empty")
            end
        elseif options and arg:sub(1, 1) == "-" and arg ~= "-" then
            return diagnostic("source", "unsupported option '" .. arg .. "'")
        elseif filename then
            return diagnostic("source", "too many operands")
        else
            filename = arg
        end
        pos = pos + 1
    end

    if not filename then
        return diagnostic("source", "missing file operand")
    end

    local file, open_error = io.open(filename, "rb")
    if not file then
        return diagnostic("source", "cannot open '" .. filename .. "': " .. open_error)
    end

    local script, read_error = file:read("*a")
    file:close()
    if not script then
        return diagnostic("source", "cannot read '" .. filename .. "': " .. read_error)
    end

    if boundary then
        local extract_error
        script, extract_error = extract_source_script(script, boundary)
        if not script then
            return diagnostic("source", filename .. ": " .. extract_error)
        end
    end

    local action = compile_source_action(filename, script)
    return action(scope, 0)
end

-- Public registry of commands understood by blud. Ordinary handlers receive
-- argv and scope; `shell` is selected before parsing and receives the verbatim
-- remainder.
M.commands = {
    cd = cd,
    cp = cp,
    echo = echo,
    mkdir = mkdir,
    rm = rm,
    shell = shell,
    source = source,
    touch = touch,
}

-- Called from Lua as `status = require("shell").execute(command, scope)`
-- (normally through blud.shell.execute()). A literal leading `shell` delegates
-- its remainder to the OS shell. Otherwise, recognized commands stay internal
-- and unrecognized commands delegate the complete original line.
function M.execute(command, scope)
    assert(not command:find("[\r\n]"))

    local shell_text = extract_shell_text(command)
    if shell_text ~= nil then
        return shell(shell_text)
    end

    local words, parse_error, command_name = parse(command)
    if not words then
        if not command_name or not M.commands[command_name] then
            return shell(command)
        end
        return diagnostic("blud", parse_error)
    end
    if #words == 0 then
        return 0
    end

    local argv = expand_words(words)
    local command_function = M.commands[argv[1]]
    if not command_function or command_function == shell then
        return shell(command)
    end

    return command_function(argv, scope)
end

return M
