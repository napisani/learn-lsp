-- context capture, including live visual-selection ranges
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq
local fresh_buffer = helpers.fresh_buffer
local lua_buffer = helpers.lua_buffer
local capture_backend_request = helpers.capture_backend_request

test("context captures visible buffer text", function()
	local vantage = require("vantage")
	local context = require("vantage.context")
	vantage.setup({ backend = { mode = "development" } })

	fresh_buffer()
	vim.bo.filetype = "lua"
	vim.api.nvim_buf_set_name(0, vim.fn.getcwd() .. "/nvim/tests/vantage-context.lua")
	vim.api.nvim_buf_set_lines(0, 0, -1, false, {
		"local x = 1",
		"local y = x + 1",
		"return y",
	})

	local captured = context.visible()
	eq(captured.language, "lua")
	eq(captured.filePath, vim.fn.getcwd() .. "/nvim/tests/vantage-context.lua")
	eq(captured.text, "local x = 1\nlocal y = x + 1\nreturn y")
	eq(captured.visibleRange.startLine, 1)
end)

test("context uses absolute file path for relative buffer name", function()
	local vantage = require("vantage")
	local context = require("vantage.context")
	vantage.setup({ backend = { mode = "development" } })

	fresh_buffer()
	vim.api.nvim_buf_set_name(0, "nvim/tests/relative-context.lua")

	local captured = context.visible()
	eq(captured.filePath, vim.fn.getcwd() .. "/nvim/tests/relative-context.lua")
end)

test("visual.live_range reads the live charwise selection", function()
	local visual = require("vantage.visual")
	lua_buffer({ "l1", "l2", "l3", "l4", "l5" })
	vim.api.nvim_win_set_cursor(0, { 2, 0 })

	vim.cmd("normal! vjj")
	local start_line, end_line = visual.live_range()
	eq({ start_line, end_line }, { 2, 4 })
	assert(visual.in_visual_mode(), "expected to still be in visual mode at call time")

	vim.cmd("normal! \27")
end)

test("visual.live_range reads a linewise V selection", function()
	local visual = require("vantage.visual")
	lua_buffer({ "l1", "l2", "l3", "l4", "l5" })
	vim.api.nvim_win_set_cursor(0, { 2, 0 })

	vim.cmd("normal! Vj")
	eq({ visual.live_range() }, { 2, 3 })

	vim.cmd("normal! \27")
end)

test("visual.live_range reads a blockwise selection", function()
	local visual = require("vantage.visual")
	lua_buffer({ "aaaa", "bbbb", "cccc" })
	vim.api.nvim_win_set_cursor(0, { 1, 1 })

	vim.cmd("normal! \22jj")
	eq({ visual.live_range() }, { 1, 3 })

	vim.cmd("normal! \27")
end)

test("visual.live_range normalizes a selection made upward", function()
	local visual = require("vantage.visual")
	lua_buffer({ "l1", "l2", "l3", "l4", "l5" })
	vim.api.nvim_win_set_cursor(0, { 4, 0 })

	-- Anchor below the cursor: raw anchor/cursor come back reversed.
	vim.cmd("normal! vkk")
	eq({ visual.live_range() }, { 2, 4 })

	vim.cmd("normal! \27")
end)

test("visual.live_range returns nil outside visual mode even after a past selection", function()
	local visual = require("vantage.visual")
	lua_buffer({ "l1", "l2", "l3", "l4" })
	vim.api.nvim_win_set_cursor(0, { 1, 0 })

	-- Make and properly close a selection, which commits '< / '>. Falling back
	-- to those marks here would make every normal-mode call silently reuse this
	-- stale selection instead of the cursor line.
	vim.cmd("normal! vj")
	vim.cmd("normal! \27")

	eq(visual.live_range(), nil)
	assert(not visual.in_visual_mode(), "expected to be out of visual mode")
end)

test("context.selected_range prefers an explicit command range over a live selection", function()
	local context = require("vantage.context")
	local vantage = require("vantage")
	vantage.setup({ backend = { mode = "development" } })
	lua_buffer({ "l1", "l2", "l3", "l4", "l5" })
	vim.api.nvim_win_set_cursor(0, { 1, 0 })

	vim.cmd("normal! vjjj")
	local params = context.selected_range({ range = 2, line1 = 2, line2 = 3 })
	eq(params.range.startLine, 2)
	eq(params.range.endLine, 3)

	vim.cmd("normal! \27")
end)

test("context.scoped falls back to the cursor line with no range and no selection", function()
	local context = require("vantage.context")
	local vantage = require("vantage")
	vantage.setup({ backend = { mode = "development" } })
	lua_buffer({ "l1", "l2", "l3" })
	vim.api.nvim_win_set_cursor(0, { 2, 0 })

	local params = context.scoped({})
	eq(params.range.startLine, 2)
	eq(params.range.endLine, 2)
	eq(params.text, "l2")
end)

test("vantage.explain called from a visual-mode Lua keymap sends the selection", function()
	local vantage = require("vantage")

	-- The bug this fixes: a keymap bound to a plain Lua function never commits
	-- '< / '>, so opts.range is absent and every command silently degraded to
	-- the cursor line instead of the user's selection.
	local captured = capture_backend_request({
		ok = true,
		result = { kind = "explanation", markdown = "Selection explanation" },
	}, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({ "local a = 1", "local b = 2", "local c = 3", "return c" })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })

		vim.cmd("normal! vj")
		vantage.explain({})
		vim.cmd("normal! \27")
	end)

	eq(captured.method, "explainSelection")
	eq(captured.params.text, "local b = 2\nlocal c = 3")
	eq(captured.params.range.startLine, 2)
	eq(captured.params.range.endLine, 3)
end)

test("vantage.context captures a live visual selection", function()
	local vantage = require("vantage")

	vantage.setup({ backend = { mode = "development" } })
	lua_buffer({ "l1", "l2", "l3", "l4" })
	vim.api.nvim_win_set_cursor(0, { 2, 0 })

	vim.cmd("normal! vj")
	local params = vantage.context()
	vim.cmd("normal! \27")

	eq(params.range.startLine, 2)
	eq(params.range.endLine, 3)
	eq(params.selectedText, "l2\nl3")
end)
