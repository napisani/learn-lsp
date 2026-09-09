-- explain / :VantageExplain, and the shared runtime= option
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq
local lua_buffer = helpers.lua_buffer
local capture_notifications = helpers.capture_notifications
local capture_backend_request = helpers.capture_backend_request

test("explain opens a markdown float for the current line", function()
	local vantage = require("vantage")
	local commands = require("vantage.commands")
	vantage.setup({ backend = { mode = "development" } })
	vantage.set_lens("learning", "I am learning Lua syntax")

	lua_buffer({ "local value = 42" })

	commands.explain()
	local float_buf = require("vantage.ui").last_float_buf()
	assert(float_buf ~= nil, "expected a float buffer")
	local text = table.concat(vim.api.nvim_buf_get_lines(float_buf, 0, -1, false), "\n")
	assert(text:match("Explanation"), text)
	assert(text:match("Lua"), text)
	assert(text:match("local value = 42"), text)
end)

test("explain with a callback skips the markdown float", function()
	local vantage = require("vantage")
	local commands = require("vantage.commands")
	vantage.setup({ backend = { mode = "development" } })
	vantage.set_lens("learning", "I am learning Lua syntax")

	lua_buffer({ "local value = 42" })

	local ui = require("vantage.ui")
	local float_buf_before = ui.last_float_buf()

	local captured_err, captured_result
	commands.explain({
		callback = function(err, result)
			captured_err = err
			captured_result = result
		end,
	})

	eq(captured_err, nil)
	assert(captured_result and captured_result.markdown, "expected result.markdown")
	assert(captured_result.markdown:match("Explanation"), captured_result.markdown)
	eq(ui.last_float_buf(), float_buf_before)
end)

test("explain notifies requesting and done for a plain call", function()
	local vantage = require("vantage")
	local commands = require("vantage.commands")
	vantage.setup({ backend = { mode = "development" } })
	vantage.set_lens("learning", "I am learning Lua syntax")

	lua_buffer({ "local value = 42" })

	local notifications = capture_notifications(function()
		commands.explain()
	end)

	local requesting, done
	for _, message in ipairs(notifications) do
		if message:match("^Vantage: requesting explanation from development$") then
			requesting = true
		end
		if message:match("^Vantage: done in") then
			done = true
		end
	end
	assert(requesting, table.concat(notifications, " | "))
	assert(done, table.concat(notifications, " | "))
end)

test("explain with a callback does not notify", function()
	local vantage = require("vantage")
	local commands = require("vantage.commands")
	vantage.setup({ backend = { mode = "development" } })
	vantage.set_lens("learning", "I am learning Lua syntax")

	lua_buffer({ "local value = 42" })

	local notifications = capture_notifications(function()
		commands.explain({
			callback = function() end,
		})
	end)

	eq(notifications, {})
end)

test("VantageExplain accepts an explicit line range", function()
	local vantage = require("vantage")

	local captured = capture_backend_request({
		ok = true,
		result = {
			kind = "explanation",
			markdown = "Range explanation",
		},
	}, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({
			"local a = 1",
			"local b = 2",
			"local c = b + 1",
			"return c",
		})

		vim.cmd("2,3VantageExplain")
	end)

	eq(captured.method, "explainSelection")
	eq(captured.params.text, "local b = 2\nlocal c = b + 1")
	eq(captured.params.selectedText, "local b = 2\nlocal c = b + 1")
	eq(captured.params.range, {
		startLine = 2,
		startCharacter = 1,
		endLine = 3,
		endCharacter = 15,
	})
end)

test("VantageExplain defaults to agent runtime", function()
	local vantage = require("vantage")

	local captured = capture_backend_request({
		ok = true,
		result = { kind = "explanation", markdown = "Explanation" },
	}, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({ "local value = 42" })
		vim.cmd("VantageExplain")
	end)

	eq(captured.params.runtime, "agent")
end)

test("VantageExplain runtime=completion reaches the backend request", function()
	local vantage = require("vantage")

	local captured = capture_backend_request({
		ok = true,
		result = { kind = "explanation", markdown = "Explanation" },
	}, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({ "local value = 42" })
		vim.cmd("VantageExplain runtime=completion")
	end)

	eq(captured.method, "explainSelection")
	eq(captured.params.runtime, "completion")
end)

test("VantageExplain rejects an invalid runtime value", function()
	local vantage = require("vantage")
	vantage.setup({ backend = { mode = "development" } })
	lua_buffer({ "local value = 42" })

	local notifications = capture_notifications(function()
		vim.cmd("VantageExplain runtime=bogus")
	end)

	assert(
		notifications[1] and notifications[1]:match('invalid runtime "bogus"'),
		vim.inspect(notifications)
	)
end)
