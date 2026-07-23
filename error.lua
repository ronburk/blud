-- Structured logical exits for bludfiles.
--
-- BLUD_ASSERT_EXIT(code, data) records the one logical exit expected by the
-- current invocation. BLUD_EXIT(code, data) exits successfully only when that
-- pair matches; BLUD_EXIT(0) records normal completion.
local expected_code
local expected_data

local function report_why()
    if blud.why then
        blud.why.report(blud.primary_targets or {})
    end
end

function BLUD_ASSERT_EXIT(code, data)
    assert(
        type(code) == "number"
            and code > 0
            and code < math.huge
            and code == math.floor(code),
        "BLUD_ASSERT_EXIT() requires a positive integer error code"
    )
    assert(
        type(data) == "string",
        "BLUD_ASSERT_EXIT() requires an error data string"
    )
    assert(
        expected_code == nil,
        "BLUD_ASSERT_EXIT() may only be called once"
    )

    expected_code = code
    expected_data = data
end

function BLUD_EXIT(code, data)
    assert(
        type(code) == "number"
            and code >= 0
            and code < math.huge
            and code == math.floor(code),
        "BLUD_EXIT() requires a nonnegative integer error code"
    )

    if code == 0 then
        assert(data == nil, "BLUD_EXIT(0) does not accept error data")

        if expected_code ~= nil then
            io.stderr:write(string.format(
                "Expected BLUD_EXIT(%d, %q), but blud completed successfully\n",
                expected_code,
                expected_data
            ))
            os.exit(1)
        end

        report_why()
        os.exit(0)
    end

    assert(type(data) == "string", "BLUD_EXIT() requires an error data string")

    if expected_code == nil then
        io.stderr:write(string.format("BLUD error %d: %s\n", code, data))
        os.exit(1)
    end

    if code == expected_code and data == expected_data then
        report_why()
        os.exit(0)
    end

    io.stderr:write(
        "BLUD_ASSERT_EXIT() did not match BLUD_EXIT():\n",
        string.format("  expected: %d, %q\n", expected_code, expected_data),
        string.format("  actual:   %d, %q\n", code, data)
    )
    os.exit(1)
end
