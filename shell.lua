-- Parse and execute one command line using blud's portable command grammar.
-- The operating-system shell is invoked only by the explicit `shell` command.
local M = {}

-- Print a command-style diagnostic and return the conventional failure status.
local function diagnostic(command, message)
    io.stderr:write(command, ": ", message, "\n")
    return 1
end

-- Filesystem-changing commands invalidate the cache shared with blud.glob.
-- The guard keeps this module usable during early initialization or in tests.
local function invalidate_directory_cache()
    if blud then
        blud.dir_cache = {}
    end
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
                return nil, "unsupported syntax '" .. c .. "'"
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
            return nil, "unsupported syntax '" .. c .. "'"
        else
            append(c, c == "*" or c == "?" or c == "[")
        end

        pos = pos + 1
    end

    if quote then
        return nil, "unterminated quote"
    end

    finish_word()
    return words
end

-- Convert parsed words to argv and expand only unquoted glob metacharacters.
-- As in default Bash behavior, an unmatched pattern remains a literal operand.
local function expand_words(words)
    local argv = {}
    local has_glob = false

    for _, word in ipairs(words) do
        has_glob = has_glob or word.glob
    end
    if has_glob then
        invalidate_directory_cache()
    end

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

    invalidate_directory_cache()
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

    invalidate_directory_cache()
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

    invalidate_directory_cache()
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

    local old_directory = os_getcwd()
    if not old_directory then
        return diagnostic("cd", "cannot determine current directory")
    end

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

    if os_setcwd(path) ~= 0 then
        return diagnostic("cd", path .. ": No such file or directory")
    end

    M.previous_directory = old_directory
    invalidate_directory_cache()
    if print_directory then
        io.stdout:write(assert(os_getcwd()), "\n")
    end
    return 0
end

-- Public registry of commands understood by blud. Ordinary handlers receive
-- argv; `shell` is selected before parsing and receives the verbatim remainder.
M.commands = {
    cd = cd,
    echo = echo,
    mkdir = mkdir,
    rm = rm,
    shell = shell,
    touch = touch,
}

-- Called from Lua as `status = require("shell").execute(command)` (normally
-- through blud.shell.execute()). `command` must be one line. A literal leading
-- `shell` delegates its remainder to the OS shell; every other command must use
-- blud's parser and one of the handlers above.
function M.execute(command)
    assert(type(command) == "string")
    assert(not command:find("[\r\n]"))

    local shell_text = extract_shell_text(command)
    if shell_text ~= nil then
        return shell(shell_text)
    end

    local words, parse_error = parse(command)
    if not words then
        return diagnostic("blud", parse_error)
    end
    if #words == 0 then
        return 0
    end

    local argv = expand_words(words)
    local command_function = M.commands[argv[1]]
    if not command_function or command_function == shell then
        return diagnostic(argv[1], "command not implemented")
    end

    return command_function(argv)
end

return M
