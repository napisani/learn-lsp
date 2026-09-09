-- the ui.input provider abstraction
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq
local lua_buffer = helpers.lua_buffer
local submit_prompt_buffer = helpers.submit_prompt_buffer
local capture_backend_request = helpers.capture_backend_request
local with_ui_input = helpers.with_ui_input
local with_fn_input = helpers.with_fn_input

test("Vantage prompts can force the ui2 input provider", function()
	local vantage = require("vantage")
	local fn_input_prompts = {}

	local captured = capture_backend_request({
		ok = true,
		result = {
			kind = "explanation",
			markdown = "UI2 question answer",
		},
	}, function()
		vantage.setup({
			backend = { mode = "development" },
			ui = {
				input = {
					provider = "ui2",
					question = {
						prompt = "UI2 question: ",
					},
					lens = {
						prompt = "UI2 lens: ",
					},
				},
			},
		})
		lua_buffer({
			"local a = 1",
			"local b = a + 1",
		})
		vim.api.nvim_win_set_cursor(0, { 2, 0 })

		with_ui_input(function()
			error("expected Vantage to bypass vim.ui.input when ui2 provider is configured")
		end, function()
			with_fn_input(function(opts)
				table.insert(fn_input_prompts, opts.prompt)
				if opts.prompt == "UI2 lens: " then
					return "Prefer concrete examples"
				end
				error("unexpected prompt: " .. tostring(opts.prompt))
			end, function()
				vim.cmd("VantageQuestion")
				submit_prompt_buffer("why does this reuse a?")
				vim.cmd("VantageSetLens learning")
			end)
		end)
	end)

	eq(fn_input_prompts, { "UI2 lens: " })
	eq(captured.method, "questionSelection")
	eq(captured.params.question, "why does this reuse a?")
	eq(vantage.get_lens(), {
		mode = "learning",
		text = "Prefer concrete examples",
	})
end)
