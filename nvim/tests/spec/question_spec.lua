-- question / :VantageQuestion
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq
local lua_buffer = helpers.lua_buffer
local submit_prompt_buffer = helpers.submit_prompt_buffer
local capture_backend_request = helpers.capture_backend_request
local with_ui_input = helpers.with_ui_input

test("VantageQuestion runtime=completion still parses the question text", function()
	local vantage = require("vantage")

	local captured = capture_backend_request({
		ok = true,
		result = { kind = "explanation", markdown = "Answer" },
	}, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({ "local value = 42" })
		vim.cmd("VantageQuestion runtime=completion why does this leak?")
	end)

	eq(captured.method, "questionSelection")
	eq(captured.params.runtime, "completion")
	eq(captured.params.question, "why does this leak?")
end)

test("VantageQuestion asks about the current line", function()
	local vantage = require("vantage")

	local captured = capture_backend_request({
		ok = true,
		result = {
			kind = "explanation",
			markdown = "Question answer",
		},
	}, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({
			"local a = 1",
			"local b = a + 1",
		})
		vim.api.nvim_win_set_cursor(0, { 2, 0 })

		vim.cmd("VantageQuestion why does this reuse a?")
	end)

	eq(captured.method, "questionSelection")
	eq(captured.params.question, "why does this reuse a?")
	eq(captured.params.text, "local b = a + 1")
	eq(captured.params.selectedText, "local b = a + 1")
end)

test("VantageQuestion opens prompt buffer for missing question text", function()
	local vantage = require("vantage")

	local captured = capture_backend_request({
		ok = true,
		result = {
			kind = "explanation",
			markdown = "Prompted question answer",
		},
	}, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({
			"local a = 1",
			"local b = a + 1",
		})
		vim.api.nvim_win_set_cursor(0, { 2, 0 })

		vim.cmd("VantageQuestion")
		submit_prompt_buffer("why does this reuse a?")
	end)

	eq(captured.method, "questionSelection")
	eq(captured.params.question, "why does this reuse a?")
	eq(captured.params.text, "local b = a + 1")
	eq(captured.params.selectedText, "local b = a + 1")
end)

test("VantageQuestion prompt buffer ignores vim.ui.input options", function()
	local vantage = require("vantage")

	local captured = capture_backend_request({
		ok = true,
		result = {
			kind = "explanation",
			markdown = "Configured question answer",
		},
	}, function()
		vantage.setup({
			backend = { mode = "development" },
			ui = {
				input = {
					question = {
						prompt = "Ask Vantage: ",
						default = "what changed here?",
						scope = "buffer",
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
			error("expected prompt buffer instead of vim.ui.input")
		end, function()
			vim.cmd("VantageQuestion")
			submit_prompt_buffer("why does this reuse a?")
		end)
	end)

	eq(captured.method, "questionSelection")
	eq(captured.params.question, "why does this reuse a?")
	eq(captured.params.text, "local b = a + 1")
end)

test("VantageQuestion accepts an explicit line range", function()
	local vantage = require("vantage")

	local captured = capture_backend_request({
		ok = true,
		result = {
			kind = "explanation",
			markdown = "Range question answer",
		},
	}, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({
			"local a = 1",
			"local b = a + 1",
			"return b",
		})

		vim.cmd("1,2VantageQuestion what is the data flow?")
	end)

	eq(captured.method, "questionSelection")
	eq(captured.params.question, "what is the data flow?")
	eq(captured.params.text, "local a = 1\nlocal b = a + 1")
	eq(captured.params.range, {
		startLine = 1,
		startCharacter = 1,
		endLine = 2,
		endCharacter = 15,
	})
end)

test("VantageQuestion opens prompt buffer for missing question text with an explicit line range", function()
	local vantage = require("vantage")

	local captured = capture_backend_request({
		ok = true,
		result = {
			kind = "explanation",
			markdown = "Prompted range question answer",
		},
	}, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({
			"local a = 1",
			"local b = a + 1",
			"return b",
		})

		vim.cmd("1,2VantageQuestion")
		submit_prompt_buffer("what is the data flow?")
	end)

	eq(captured.method, "questionSelection")
	eq(captured.params.question, "what is the data flow?")
	eq(captured.params.text, "local a = 1\nlocal b = a + 1")
	eq(captured.params.range, {
		startLine = 1,
		startCharacter = 1,
		endLine = 2,
		endCharacter = 15,
	})
end)
