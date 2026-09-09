-- annotate / :VantageAnnotate argument parsing, scopes, and runtime
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq
local lua_buffer = helpers.lua_buffer
local capture_backend_request = helpers.capture_backend_request

test("annotate defaults to the current line", function()
	local vantage = require("vantage")
	local commands = require("vantage.commands")
	local annotations = require("vantage.annotations")

	local captured = capture_backend_request(nil, function()
		vantage.setup({ backend = { mode = "development" } })
		annotations.clear(0)
		lua_buffer({
			"-- heading",
			"",
			"local total = 0",
			"for index = 1, 3 do",
			"  total = total + index",
			"end",
		})
		vim.api.nvim_win_set_cursor(0, { 3, 0 })

		commands.annotate()
		commands.clear_annotations()
	end)

	annotations.clear(0)
	eq(captured.params.text, "local total = 0")
	eq(captured.params.scopeText, "local total = 0")
	eq(captured.params.visibleRange, {
		startLine = 3,
		startCharacter = 1,
		endLine = 3,
		endCharacter = 15,
	})
	eq(captured.params.maxAnnotations, 1)
	eq(captured.params.candidateLines, {
		{ line = 3, text = "local total = 0" },
	})
end)

test("VantageAnnotate line scopes annotation to the current line", function()
	local vantage = require("vantage")
	local commands = require("vantage.commands")
	local annotations = require("vantage.annotations")

	local captured = capture_backend_request(nil, function()
		vantage.setup({ backend = { mode = "development" } })
		annotations.clear(0)
		lua_buffer({
			"local before = 1",
			"local target = before + 1",
			"local after = target + 1",
		})
		vim.api.nvim_win_set_cursor(0, { 2, 0 })

		vim.cmd("VantageAnnotate line")
		commands.clear_annotations()
	end)

	annotations.clear(0)
	eq(captured.method, "annotateRange")
	eq(captured.params.text, "local target = before + 1")
	eq(captured.params.scopeText, "local target = before + 1")
	eq(captured.params.visibleRange, {
		startLine = 2,
		startCharacter = 1,
		endLine = 2,
		endCharacter = 25,
	})
	eq(captured.params.maxAnnotations, 1)
	eq(captured.params.candidateLines, {
		{ line = 2, text = "local target = before + 1" },
	})
end)

test("VantageAnnotate defaults to agent runtime", function()
	local vantage = require("vantage")
	local commands = require("vantage.commands")
	local annotations = require("vantage.annotations")

	local captured = capture_backend_request(nil, function()
		vantage.setup({ backend = { mode = "development" } })
		annotations.clear(0)
		lua_buffer({ "local value = 42" })
		vim.cmd("VantageAnnotate")
		commands.clear_annotations()
	end)

	annotations.clear(0)
	eq(captured.params.runtime, "agent")
end)

test("VantageAnnotate runtime=completion composes with the scope/count args", function()
	local vantage = require("vantage")
	local commands = require("vantage.commands")
	local annotations = require("vantage.annotations")

	local captured = capture_backend_request(nil, function()
		vantage.setup({ backend = { mode = "development" } })
		annotations.clear(0)
		lua_buffer({
			"local before = 1",
			"local target = before + 1",
			"local after = target + 1",
		})
		vim.cmd("VantageAnnotate runtime=completion buffer 2")
		commands.clear_annotations()
	end)

	annotations.clear(0)
	eq(captured.method, "annotateRange")
	eq(captured.params.runtime, "completion")
	eq(captured.params.maxAnnotations, 2)
end)

test("VantageAnnotate visible uses the visible range and lets the model choose oversized scopes", function()
	local vantage = require("vantage")
	local commands = require("vantage.commands")
	local annotations = require("vantage.annotations")

	local captured = capture_backend_request(nil, function()
		vantage.setup({ backend = { mode = "development" } })
		annotations.clear(0)
		lua_buffer({
			"local one = 1",
			"local two = one + 1",
			"local three = two + 1",
			"local four = three + 1",
			"local five = four + 1",
			"local six = five + 1",
			"local seven = six + 1",
		})
		vim.api.nvim_win_set_cursor(0, { 1, 0 })

		vim.cmd("VantageAnnotate visible")
		commands.clear_annotations()
	end)

	annotations.clear(0)
	eq(captured.params.maxAnnotations, 2)
	eq(captured.params.scopeText, table.concat({
		"local one = 1",
		"local two = one + 1",
		"local three = two + 1",
		"local four = three + 1",
		"local five = four + 1",
		"local six = five + 1",
		"local seven = six + 1",
	}, "\n"))
	eq(captured.params.visibleRange, {
		startLine = 1,
		startCharacter = 1,
		endLine = 7,
		endCharacter = 21,
	})
	eq(captured.params.candidateLines, nil)
end)

test("VantageAnnotate buffer uses full-buffer scope with percentage budget", function()
	local vantage = require("vantage")
	local commands = require("vantage.commands")
	local annotations = require("vantage.annotations")

	local captured = capture_backend_request(nil, function()
		vantage.setup({ backend = { mode = "development" } })
		annotations.clear(0)
		lua_buffer({
			"-- setup",
			"",
			"local one = 1",
			"local two = one + 1",
			"local three = two + 1",
			"local four = three + 1",
			"local five = four + 1",
			"local six = five + 1",
			"local seven = six + 1",
			"local eight = seven + 1",
			"local nine = eight + 1",
			"local ten = nine + 1",
		})
		vim.api.nvim_win_set_cursor(0, { 5, 0 })

		vim.cmd("VantageAnnotate buffer")
		commands.clear_annotations()
	end)

	annotations.clear(0)
	eq(captured.method, "annotateRange")
	eq(captured.params.maxAnnotations, 3)
	eq(captured.params.scopeText, table.concat({
		"-- setup",
		"",
		"local one = 1",
		"local two = one + 1",
		"local three = two + 1",
		"local four = three + 1",
		"local five = four + 1",
		"local six = five + 1",
		"local seven = six + 1",
		"local eight = seven + 1",
		"local nine = eight + 1",
		"local ten = nine + 1",
	}, "\n"))
	eq(captured.params.visibleRange, {
		startLine = 1,
		startCharacter = 1,
		endLine = 12,
		endCharacter = 20,
	})
	eq(captured.params.candidateLines, nil)
end)

test("VantageAnnotate numeric argument keeps the current-line default scope", function()
	local vantage = require("vantage")
	local commands = require("vantage.commands")
	local annotations = require("vantage.annotations")

	local captured = capture_backend_request(nil, function()
		vantage.setup({ backend = { mode = "development" } })
		annotations.clear(0)
		lua_buffer({
			"local one = 1",
			"local two = one + 1",
			"local three = two + 1",
			"local four = three + 1",
			"local five = four + 1",
			"local six = five + 1",
		})
		vim.api.nvim_win_set_cursor(0, { 2, 0 })

		vim.cmd("VantageAnnotate 5")
		commands.clear_annotations()
	end)

	annotations.clear(0)
	eq(captured.params.maxAnnotations, 5)
	eq(captured.params.scopeText, "local two = one + 1")
	eq(captured.params.candidateLines, {
		{ line = 2, text = "local two = one + 1" },
	})
end)

test("VantageAnnotate accepts an explicit line range", function()
	local vantage = require("vantage")
	local annotations = require("vantage.annotations")

	local captured = capture_backend_request({
		ok = true,
		result = {
			kind = "annotations",
			annotations = {
				{
					text = "Range annotation",
					severity = "info",
					range = {
						startLine = 2,
						startCharacter = 1,
						endLine = 2,
						endCharacter = 9,
					},
				},
			},
		},
	}, function()
		vantage.setup({ backend = { mode = "development" } })
		annotations.clear(0)
		lua_buffer({
			"local a = 1",
			"local b = 2",
			"local c = b + 1",
			"return c",
		})

		vim.cmd("2,4VantageAnnotate")
	end)

	annotations.clear(0)
	eq(captured.method, "annotateRange")
	eq(captured.params.scopeText, "local b = 2\nlocal c = b + 1\nreturn c")
	eq(captured.params.visibleRange, {
		startLine = 2,
		startCharacter = 1,
		endLine = 4,
		endCharacter = 8,
	})
	eq(captured.params.range, {
		startLine = 2,
		startCharacter = 1,
		endLine = 4,
		endCharacter = 8,
	})
	eq(captured.params.maxAnnotations, 1)
	eq(captured.params.candidateLines, nil)
end)

test("VantageAnnotate range lets the model choose oversized selections", function()
	local vantage = require("vantage")
	local annotations = require("vantage.annotations")

	local captured = capture_backend_request(nil, function()
		vantage.setup({ backend = { mode = "development" } })
		annotations.clear(0)
		lua_buffer({
			"local a = 1",
			"local b = a + 1",
			"local c = b + 1",
			"local d = c + 1",
		})

		vim.cmd("1,4VantageAnnotate")
	end)

	annotations.clear(0)
	eq(captured.method, "annotateRange")
	eq(captured.params.maxAnnotations, 1)
	eq(captured.params.scopeText, "local a = 1\nlocal b = a + 1\nlocal c = b + 1\nlocal d = c + 1")
	eq(captured.params.visibleRange, {
		startLine = 1,
		startCharacter = 1,
		endLine = 4,
		endCharacter = 15,
	})
	eq(captured.params.candidateLines, nil)
end)
