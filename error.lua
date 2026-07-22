-- Structured logical exits for bludfiles.
--
-- BLUD_ASSERT_EXIT(code, text) records the one logical exit expected by the
-- current invocation. BLUD_EXIT(code, text) exits successfully only when that
-- pair matches; otherwise it reports the logical error or mismatch and fails.
local expected_code
local expected_text

function BLUD_ASSERT_EXIT(code, text)
    assert(
        type(code) == "number"
            and code > 0
            and code < math.huge
            and code == math.floor(code),
        "BLUD_ASSERT_EXIT() requires a positive integer error code"
    )
    assert(
        type(text) == "string",
        "BLUD_ASSERT_EXIT() requires an error data string"
    )
    assert(
        expected_code == nil,
        "BLUD_ASSERT_EXIT() may only be called once"
    )

    expected_code = code
    expected_text = text
end

function BLUD_EXIT(code, text)
    assert(
        type(code) == "number"
            and code > 0
            and code < math.huge
            and code == math.floor(code),
        "BLUD_EXIT() requires a positive integer error code"
    )
    assert(type(text) == "string", "BLUD_EXIT() requires an error data string")

    if expected_code == nil then
        io.stderr:write(string.format("BLUD error %d: %s\n", code, text))
        os.exit(1)
    end

    if code == expected_code and text == expected_text then
        os.exit(0)
    end

    io.stderr:write(
        "BLUD_ASSERT_EXIT() did not match BLUD_EXIT():\n",
        string.format("  expected: %d, %q\n", expected_code, expected_text),
        string.format("  actual:   %d, %q\n", code, text)
    )
    os.exit(1)
end

return function()
    if expected_code ~= nil then
        io.stderr:write(string.format(
            "Expected BLUD_EXIT(%d, %q), but blud completed successfully\n",
            expected_code,
            expected_text
        ))
        os.exit(1)
    end
end
