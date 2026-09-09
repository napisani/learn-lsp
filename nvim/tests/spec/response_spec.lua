-- response.unwrap / error_message result unwrapping
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq

test("response.unwrap returns result on an ok response", function()
	local response_util = require("vantage.response")
	local result, err = response_util.unwrap({ ok = true, result = { kind = "edit", replacementText = "x" } })
	eq(err, nil)
	eq(result, { kind = "edit", replacementText = "x" })
end)

test("response.error_message reads a string-shaped error", function()
	local response_util = require("vantage.response")
	eq(response_util.error_message({ ok = false, error = "boom" }), "boom")
end)

test("response.error_message reads a table-shaped error", function()
	local response_util = require("vantage.response")
	eq(response_util.error_message({ ok = false, error = { message = "boom", code = "bad_request" } }), "boom")
end)

test("response.error_message falls back when error is missing", function()
	local response_util = require("vantage.response")
	eq(response_util.error_message(nil), "Unknown backend error.")
	eq(response_util.error_message({ ok = false }), "Unknown backend error.")
end)

test("response.unwrap fails on a not-ok response with the error markdown", function()
	local response_util = require("vantage.response")
	local result, err = response_util.unwrap({ ok = false, error = { message = "boom" } })
	eq(result, nil)
	eq(err, "## Error\n\nboom")
end)

test("response.unwrap fails when result.kind does not match expected_kind", function()
	local response_util = require("vantage.response")
	local result, err = response_util.unwrap({ ok = true, result = { kind = "other" } }, "edit")
	eq(result, nil)
	eq(err, "## Error\n\nBackend returned an invalid edit response.")
end)

test("response.unwrap fails when result is missing but expected_kind is given", function()
	local response_util = require("vantage.response")
	local result, err = response_util.unwrap({ ok = true }, "skills")
	eq(result, nil)
	eq(err, "## Error\n\nBackend returned an invalid skills response.")
end)

test("response.unwrap uses a custom invalid_kind_message when given", function()
	local response_util = require("vantage.response")
	local result, err =
		response_util.unwrap({ ok = true, result = { kind = "other" } }, "locations", "Backend returned an invalid search response.")
	eq(result, nil)
	eq(err, "## Error\n\nBackend returned an invalid search response.")
end)
