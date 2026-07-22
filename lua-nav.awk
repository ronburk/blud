# Locate named Lua functions directly from source files.
#
# Examples:
#   awk -f lua-nav.awk -- get_line *.lua
#   awk -f lua-nav.awk -- --file compile_io.lua get_token *.lua
#   awk -f lua-nav.awk -- --regex 'token|line' *.lua
#   awk -f lua-nav.awk -- --list compile_io.lua *.lua
#   awk -f lua-nav.awk -- --source get_line *.lua

BEGIN {
    mode = "exact"
    source_mode = 0
    query = ""
    file_filter = ""

    parse_arguments()
    if (showed_help || argument_error)
        exit argument_status
}

FNR == 1 {
    begin_file(FILENAME)
}

{
    line_text[FILENAME SUBSEP FNR] = $0
    tokenize_line($0, FNR, FILENAME)
}

END {
    if (showed_help || argument_error)
        exit argument_status

    parse_functions()
    exit output_matches()
}

function usage(stream) {
    print "usage:" > stream
    print "  awk -f lua-nav.awk -- [--source] [--file file] name files..." > stream
    print "  awk -f lua-nav.awk -- [--source] --regex regexp files..." > stream
    print "  awk -f lua-nav.awk -- [--source] --list file files..." > stream
    print "" > stream
    print "Exact name searches also match the final component of dotted or" > stream
    print "colon-qualified names." > stream
}

function fail_arguments(message) {
    print "lua-nav.awk: " message > "/dev/stderr"
    usage("/dev/stderr")
    argument_error = 1
    argument_status = 2
}

function parse_arguments(    i, arg, input_count) {
    i = 1
    while (i < ARGC) {
        arg = ARGV[i]

        if (arg == "--help") {
            ARGV[i] = ""
            usage("/dev/stdout")
            showed_help = 1
            argument_status = 0
            return
        }

        if (arg == "--source") {
            source_mode = 1
            ARGV[i] = ""
            ++i
            continue
        }

        if (arg == "--file") {
            if (i + 1 >= ARGC) {
                fail_arguments("--file requires a file name")
                return
            }
            file_filter = ARGV[i + 1]
            ARGV[i] = ARGV[i + 1] = ""
            i += 2
            continue
        }

        if (arg == "--regex") {
            if (i + 1 >= ARGC) {
                fail_arguments("--regex requires a regular expression")
                return
            }
            mode = "regex"
            query = ARGV[i + 1]
            ARGV[i] = ARGV[i + 1] = ""
            i += 2
            break
        }

        if (arg == "--list") {
            if (i + 1 >= ARGC) {
                fail_arguments("--list requires a file name")
                return
            }
            mode = "list"
            file_filter = ARGV[i + 1]
            ARGV[i] = ARGV[i + 1] = ""
            i += 2
            break
        }

        if (substr(arg, 1, 2) == "--") {
            fail_arguments("unknown option: " arg)
            return
        }

        query = arg
        ARGV[i] = ""
        ++i
        break
    }

    if (mode == "exact" && query == "") {
        fail_arguments("missing function name")
        return
    }

    for (; i < ARGC; ++i) {
        if (ARGV[i] != "")
            ++input_count
    }

    if (!input_count)
        fail_arguments("missing Lua source files")
}

function begin_file(file,    i) {
    file_order[++file_count] = file
    file_token_first[file] = token_count + 1

    lexer_state = "normal"
    long_level = -1
    short_quote = ""
    short_text = ""
    short_start_line = 0

    for (i in block_stack)
        delete block_stack[i]
}

function add_token(text, type, line, file) {
    ++token_count
    token_text[token_count] = text
    token_type[token_count] = type
    token_line[token_count] = line
    file_token_last[file] = token_count
}

function long_open_level(text, pos,    i, level) {
    if (substr(text, pos, 1) != "[")
        return -1

    i = pos + 1
    while (substr(text, i, 1) == "=") {
        ++level
        ++i
    }

    if (substr(text, i, 1) == "[")
        return level

    return -1
}

function long_close_length(text, pos, level,    i, n) {
    if (substr(text, pos, 1) != "]")
        return 0

    i = pos + 1
    for (n = 0; n < level; ++n) {
        if (substr(text, i, 1) != "=")
            return 0
        ++i
    }

    if (substr(text, i, 1) == "]")
        return level + 2

    return 0
}

function is_identifier_start(c) {
    return c ~ /^[A-Za-z_]$/
}

function is_identifier_char(c) {
    return c ~ /^[A-Za-z0-9_]$/
}

function tokenize_line(text, line, file,    pos, length_, c, c2, c3, previous, level, close_len, start) {
    pos = 1
    length_ = length(text)

    while (pos <= length_) {
        if (lexer_state == "long_comment" || lexer_state == "long_string") {
            close_len = long_close_length(text, pos, long_level)
            if (close_len) {
                if (lexer_state == "long_string")
                    add_token("<long-string>", "string", long_start_line, file)
                lexer_state = "normal"
                long_level = -1
                pos += close_len
            } else {
                ++pos
            }
            continue
        }

        if (lexer_state == "short_string") {
            c = substr(text, pos, 1)
            short_text = short_text c
            ++pos

            if (short_escaped) {
                short_escaped = 0
            } else if (c == "\\") {
                short_escaped = 1
            } else if (c == short_quote) {
                add_token(short_text, "string", short_start_line, file)
                lexer_state = "normal"
                short_quote = ""
                short_text = ""
            }
            continue
        }

        c = substr(text, pos, 1)
        c2 = substr(text, pos, 2)
        c3 = substr(text, pos, 3)

        if (c ~ /^[ \t\r\f\v]$/) {
            ++pos
            continue
        }

        if (c2 == "--") {
            level = long_open_level(text, pos + 2)
            if (level >= 0) {
                lexer_state = "long_comment"
                long_level = level
                pos += level + 4
                continue
            }
            break
        }

        if (c == "\"" || c == "'") {
            lexer_state = "short_string"
            short_quote = c
            short_text = c
            short_start_line = line
            short_escaped = 0
            ++pos
            continue
        }

        level = long_open_level(text, pos)
        if (level >= 0) {
            lexer_state = "long_string"
            long_level = level
            long_start_line = line
            pos += level + 2
            continue
        }

        if (is_identifier_start(c)) {
            start = pos
            ++pos
            while (pos <= length_ && is_identifier_char(substr(text, pos, 1)))
                ++pos
            add_token(substr(text, start, pos - start), "identifier", line, file)
            continue
        }

        if (c ~ /^[0-9]$/) {
            start = pos
            ++pos
            while (pos <= length_) {
                c = substr(text, pos, 1)
                c2 = substr(text, pos, 2)
                previous = substr(text, pos - 1, 1)
                if (c2 == "..")
                    break
                if (c ~ /^[A-Za-z0-9_.]$/)
                    ++pos
                else if ((c == "+" || c == "-") && previous ~ /^[eEpP]$/)
                    ++pos
                else
                    break
            }
            add_token(substr(text, start, pos - start), "number", line, file)
            continue
        }

        if (c3 == "...") {
            add_token(c3, "symbol", line, file)
            pos += 3
            continue
        }

        if (c2 ~ /^(\.\.|::|==|~=|<=|>=|\/\/|<<|>>|->)$/) {
            add_token(c2, "symbol", line, file)
            pos += 2
            continue
        }

        add_token(c, "symbol", line, file)
        ++pos
    }

    if (lexer_state == "short_string") {
        short_text = short_text "\n"
        if (short_escaped)
            short_escaped = 0
    }
}

function parse_declaration_name(pos, last,    name, i) {
    parsed_name = ""
    parsed_after_name = pos

    if (pos > last || token_type[pos] != "identifier")
        return 0

    name = token_text[pos]
    i = pos + 1
    while (i + 1 <= last && (token_text[i] == "." || token_text[i] == ":") && token_type[i + 1] == "identifier") {
        name = name token_text[i] token_text[i + 1]
        i += 2
    }

    parsed_name = name
    parsed_after_name = i
    return 1
}

function find_closing_paren(open, last,    depth, i, text) {
    depth = 0
    for (i = open; i <= last; ++i) {
        text = token_text[i]
        if (text == "(")
            ++depth
        else if (text == ")") {
            --depth
            if (!depth)
                return i
        }
    }
    return 0
}

function render_parameters(open, close_pos,    result, i, text) {
    result = "("
    for (i = open + 1; i < close_pos; ++i) {
        text = token_text[i]
        if (text == ",")
            result = result ", "
        else
            result = result text
    }
    return result ")"
}

function is_lhs_delimiter(text) {
    return text == "local" || text == "return" || text == ";" || text == "," || \
           text == "{" || text == "}" || text == "then" || text == "do" || \
           text == "end" || text == "else" || text == "elseif" || text == "until"
}

function assignment_name(eq, first,    i, start, square, paren, brace, text, candidate) {
    i = eq - 1
    square = paren = brace = 0

    for (; i >= first; --i) {
        text = token_text[i]

        if (text == "]")
            ++square
        else if (text == "[") {
            if (square)
                --square
            else
                break
        } else if (text == ")") {
            if (!square && !paren && !brace)
                break
            ++paren
        } else if (text == "(") {
            if (paren)
                --paren
            else
                break
        } else if (text == "}") {
            if (!square && !paren && !brace)
                break
            ++brace
        } else if (text == "{") {
            if (brace)
                --brace
            else
                break
        } else if (!square && !paren && !brace && is_lhs_delimiter(text)) {
            break
        }
    }

    start = i + 1
    candidate = ""
    for (i = start; i < eq; ++i)
        candidate = candidate token_text[i]

    if (candidate !~ /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*|:[A-Za-z_][A-Za-z0-9_]*|\[[^][]+\])*$/)
        return ""

    assignment_start = start
    return candidate
}

function clear_block_stack(    i) {
    for (i in block_stack)
        delete block_stack[i]
}

function find_function_end(function_token, last,    depth, i, text) {
    clear_block_stack()
    depth = 1
    block_stack[depth] = "end"

    for (i = function_token + 1; i <= last; ++i) {
        text = token_text[i]

        if (text == "function" || text == "if") {
            block_stack[++depth] = "end"
        } else if (text == "for" || text == "while") {
            block_stack[++depth] = "loop-do"
        } else if (text == "repeat") {
            block_stack[++depth] = "until"
        } else if (text == "do") {
            if (block_stack[depth] == "loop-do")
                block_stack[depth] = "end"
            else
                block_stack[++depth] = "end"
        } else if (text == "end") {
            if (block_stack[depth] == "end") {
                delete block_stack[depth]
                --depth
                if (!depth)
                    return token_line[i]
            }
        } else if (text == "until") {
            if (block_stack[depth] == "until") {
                delete block_stack[depth]
                --depth
            }
        }
    }

    return 0
}

function add_function(file, start_line, end_line, name, parameters) {
    ++function_count
    function_file[function_count] = file
    function_start[function_count] = start_line
    function_end[function_count] = end_line
    function_name[function_count] = name
    function_parameters[function_count] = parameters
}

function parse_file_functions(file, first, last,    i, open, close_pos, end_line, name, start_line) {
    for (i = first; i <= last; ++i) {
        if (token_text[i] != "function")
            continue

        name = ""
        open = 0
        start_line = token_line[i]

        if (parse_declaration_name(i + 1, last) && token_text[parsed_after_name] == "(") {
            name = parsed_name
            open = parsed_after_name
        } else if (token_text[i + 1] == "(" && token_text[i - 1] == "=") {
            name = assignment_name(i - 1, first)
            if (name != "") {
                open = i + 1
                start_line = token_line[assignment_start]
            }
        }

        if (name == "" || !open)
            continue

        close_pos = find_closing_paren(open, last)
        if (!close_pos)
            continue

        end_line = find_function_end(i, last)
        if (!end_line)
            continue

        add_function(file, start_line, end_line, name, render_parameters(open, close_pos))
    }
}

function parse_functions(    n, file, first, last) {
    for (n = 1; n <= file_count; ++n) {
        file = file_order[n]
        first = file_token_first[file]
        last = file_token_last[file]
        if (first && last && first <= last)
            parse_file_functions(file, first, last)
    }
}

function base_name(path,    result) {
    result = path
    sub(/^.*\//, "", result)
    return result
}

function file_matches(path) {
    return file_filter == "" || path == file_filter || base_name(path) == file_filter
}

function short_function_name(name,    result) {
    result = name
    sub(/^.*[.:]/, "", result)
    return result
}

function function_matches(record,    name) {
    if (!file_matches(function_file[record]))
        return 0

    name = function_name[record]
    if (mode == "list")
        return 1
    if (mode == "regex")
        return name ~ query
    return name == query || short_function_name(name) == query
}

function print_function(record,    file, line) {
    file = function_file[record]
    if (!source_mode) {
        printf "%s:%d-%d\t%s%s\n", file, function_start[record], function_end[record], \
               function_name[record], function_parameters[record]
        return
    }

    if (printed_source)
        print ""
    printf "@@ %s:%d-%d %s%s\n", file, function_start[record], function_end[record], \
           function_name[record], function_parameters[record]
    for (line = function_start[record]; line <= function_end[record]; ++line)
        print line_text[file SUBSEP line]
    printed_source = 1
}

function output_matches(    i, matches) {
    for (i = 1; i <= function_count; ++i) {
        if (function_matches(i)) {
            print_function(i)
            ++matches
        }
    }

    if (!matches)
        return 1
    return 0
}
