-- Structured logical exits for bludfiles.
--
-- BLUD_ASSERT_EXIT(code, text) records the one logical exit expected by the
-- current invocation. BLUD_EXIT(code, text) exits successfully only when that
-- pair matches; otherwise it reports the logical error or mismatch and fails.
local M = {}

local expected_code
local expected_text

local function require_code(code, function_name)
    if type(code) ~= "number" or code <= 0 or code == math.huge
            or code ~= math.floor(code) then
        error(function_name .. "() requires a positive integer error code", 3)
    end
end

local function require_text(text, function_name)
    if type(text) ~= "string" then
        error(function_name .. "() requires an error data string", 3)
    end
end

local function write_line(text)
    io.stderr:write(text, "\n")
end

function M.assert_exit(code, text)
    require_code(code, "BLUD_ASSERT_EXIT")
    require_text(text, "BLUD_ASSERT_EXIT")

    if expected_code ~= nil then
        error("BLUD_ASSERT_EXIT() may only be called once", 2)
    end

    expected_code = code
    expected_text = text
end

function M.exit(code, text)
    require_code(code, "BLUD_EXIT")
    require_text(text, "BLUD_EXIT")

    if expected_code == nil then
        write_line(string.format("BLUD error %d: %s", code, text))
        os.exit(1)
    end

    if code == expected_code and text == expected_text then
        os.exit(0)
    end

    write_line("BLUD_ASSERT_EXIT() did not match BLUD_EXIT():")
    write_line(string.format(
        "  expected: %d, %q",
        expected_code,
        expected_text
    ))
    write_line(string.format("  actual:   %d, %q", code, text))
    os.exit(1)
end

function M.finish()
    if expected_code == nil then
        return
    end

    write_line(string.format(
        "Expected BLUD_EXIT(%d, %q), but blud completed successfully",
        expected_code,
        expected_text
    ))
    os.exit(1)
end

BLUD_ASSERT_EXIT = M.assert_exit
BLUD_EXIT = M.exit

return M
