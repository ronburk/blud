--[[
    
New approach. You're going to write a new function called
get_line. You will keep it and its associated code in "scratch.lua"
Tell me what's missing from this spec:

parsed = get_line(next_func)

Where:
    next_func is a function parses the next line of text and returns:

    parsed is a table with these fields:
        type: "LUA" or "ASSIGN" or "ACTION" or "UNKNOWN" or "POP" or "COMMENT"
        keyword: if line starts with Lua keyword, text of that keyword, else nil
        parts: result of running macro.lua's parts_from_text on the "real"
            portion of the line
        line: the entire original line
        virtual_line: the entire original line minus prefix that was stripped

get_line() calls next_func() to get next line of text. It maintains an
internal 'mode' variable that is either "LUA" or "DIRECTIVE" or
"ACTION". This is initially set to "DIRECTIVE".

It also maintains an internal 'strip_stack', which contains a stack of
prefix contexts it is currently stripping off of input lines to get to
the "virtual" line. This is initially empty. Each element of
strip_stack is a table: { prefix, mode }

get_line first handles push/pop operations on the strip_stack. It
begins by trying to strip each prefix on the stack, bottom to top. If
it cannot find all the prefixes in order, it pops the topmost element,
sets the current mode to that element's .mode and returns a POP type.
The next call to get_line will operate on these same line instead of
calling next_func.
    
If it does find all the prefixes, then it sets its result virtual_line
to the remainder of the line. It next checks the beginning of virtual_line
for the presence of a new prefix. A prefix is one of three forms:
    <whitespace>:<space>
         or
    <whitespace>$<space>
         or
    <whitespace><not white-space>

If the line starts with one of these patterns, the prefix text matched
is stripped and pushed onto the strip_stack before proceeding. The
current 'mode' is also pushed with that same entry. If the new prefix
was a colon type, our mode is set to DIRECTIVE. If it was the dollar
sign type then the mode is set to ACTION. There is an exception: if
the current mode is LUA and the prefix is just whitespace, we pretend
we saw no prefix at all

Now we have the final virtual_line to analyze. parts_to_text is called
to produce a 'parts' array from virtual_line. The analysis depends on
the current mode:

In DIRECTIVE mode, 

]]--
