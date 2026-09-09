-- lens set/clear prompting
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq
local with_ui_input = helpers.with_ui_input

test("VantageSetLens prompts for missing lens text", function()
	local vantage = require("vantage")

	vantage.setup({ backend = { mode = "development" } })

	with_ui_input(function(opts, callback)
		eq(opts.prompt, "Vantage lens: ")
		callback("I am learning Lua syntax")
	end, function()
		vim.cmd("VantageSetLens learning")
	end)

	eq(vantage.get_lens(), {
		mode = "learning",
		text = "I am learning Lua syntax",
	})
end)

test("VantageSetLens prompt uses configured vim.ui.input options", function()
	local vantage = require("vantage")

	vantage.setup({
		backend = { mode = "development" },
		ui = {
			input = {
				lens = {
					prompt = "Lens: ",
					default = "Review naming clarity",
					scope = "global",
				},
			},
		},
	})

	with_ui_input(function(opts, callback)
		eq(opts.prompt, "Lens: ")
		eq(opts.default, "Review naming clarity")
		eq(opts.scope, "global")
		callback("Check data flow")
	end, function()
		vim.cmd("VantageSetLens review")
	end)

	eq(vantage.get_lens(), {
		mode = "review",
		text = "Check data flow",
	})
end)
