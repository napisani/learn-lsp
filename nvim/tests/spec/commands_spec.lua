-- user-command registration
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")


test("registers unified explain command without selection or line variants", function()
	local vantage = require("vantage")

	vantage.setup({ backend = { mode = "development" } })

	assert(vim.fn.exists(":VantageExplain") == 2, "expected VantageExplain command")
	assert(vim.fn.exists(":VantageQuestion") == 2, "expected VantageQuestion command")
	assert(vim.fn.exists(":VantageEdit") == 2, "expected VantageEdit command")
	assert(vim.fn.exists(":VantageSessionOutput") == 2, "expected VantageSessionOutput command")
	assert(vim.fn.exists(":VantageExplainSelection") == 0, "expected old selection command to be removed")
	assert(vim.fn.exists(":VantageExplainLine") == 0, "expected old line command to be removed")
end)

test("registers explicit annotation commands without toggle command", function()
	local vantage = require("vantage")

	vantage.setup({ backend = { mode = "development" } })

	assert(vim.fn.exists(":VantageAnnotate") == 2, "expected VantageAnnotate command")
	assert(vim.fn.exists(":VantageAnnotationClear") == 2, "expected VantageAnnotationClear command")
	assert(vim.fn.exists(":VantageToggleAnnotations") == 0, "expected old toggle command to be removed")
end)
