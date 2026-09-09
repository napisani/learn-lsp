-- the output popup, keybind hints, and promote-to-split
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq
local lua_buffer = helpers.lua_buffer
local prompt_buffer_footer_text = helpers.prompt_buffer_footer_text
local capture_backend_request = helpers.capture_backend_request

test("VantageExplain output popup shows a close/promote keybind footer", function()
	local vantage = require("vantage")
	local ui = require("vantage.ui")

	vantage.setup({ backend = { mode = "development" } })
	lua_buffer({ "local a = 1" })

	capture_backend_request({
		ok = true,
		result = { kind = "explanation", markdown = "answer" },
	}, function()
		vim.cmd("VantageExplain")
	end)

	eq(prompt_buffer_footer_text(), ' close q  promote <leader>"  vsplit <leader>% ')
	vim.api.nvim_win_close(ui.last_float_win(), true)
end)

test("VantageExplain output popup has no footer when ui.keybind_hints is false", function()
	local vantage = require("vantage")
	local ui = require("vantage.ui")

	vantage.setup({ backend = { mode = "development" }, ui = { keybind_hints = false } })
	lua_buffer({ "local a = 1" })

	capture_backend_request({
		ok = true,
		result = { kind = "explanation", markdown = "answer" },
	}, function()
		vim.cmd("VantageExplain")
	end)

	eq(prompt_buffer_footer_text(), nil)
	vim.api.nvim_win_close(ui.last_float_win(), true)
end)

test("VantageExplain output popup promotes to a horizontal split with <leader>\" by default", function()
	local vantage = require("vantage")
	local ui = require("vantage.ui")

	vantage.setup({ backend = { mode = "development" } })
	lua_buffer({ "local a = 1" })

	capture_backend_request({
		ok = true,
		result = { kind = "explanation", markdown = "answer" },
	}, function()
		vim.cmd("VantageExplain")
	end)

	local popup_win = ui.last_float_win()
	vim.api.nvim_set_current_win(popup_win)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<leader>"', true, false, true), "x", false)

	assert(not vim.api.nvim_win_is_valid(popup_win), "expected the popup window to close after promotion")
	local promoted_win = ui.last_float_win()
	eq(vim.api.nvim_win_get_config(promoted_win).relative, "")
	eq(vim.api.nvim_win_get_option(promoted_win, "statusline"), " close q ")

	vim.api.nvim_win_close(promoted_win, true)
end)

test("VantageExplain output popup promotes to a vertical split with <leader>% by default", function()
	local vantage = require("vantage")
	local ui = require("vantage.ui")

	vantage.setup({ backend = { mode = "development" } })
	lua_buffer({ "local a = 1" })

	capture_backend_request({
		ok = true,
		result = { kind = "explanation", markdown = "answer" },
	}, function()
		vim.cmd("VantageExplain")
	end)

	local popup_win = ui.last_float_win()
	vim.api.nvim_set_current_win(popup_win)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<leader>%", true, false, true), "x", false)

	assert(not vim.api.nvim_win_is_valid(popup_win), "expected the popup window to close after promotion")
	local promoted_win = ui.last_float_win()
	eq(vim.api.nvim_win_get_config(promoted_win).relative, "")
	eq(vim.api.nvim_win_get_option(promoted_win, "statusline"), " close q ")

	vim.api.nvim_win_close(promoted_win, true)
end)

test("Promoting an output popup still closes it after a prompt buffer clobbers ui.last_float_win", function()
	local vantage = require("vantage")
	local ui = require("vantage.ui")

	vantage.setup({ backend = { mode = "development" } })
	lua_buffer({ "local a = 1" })

	capture_backend_request({
		ok = true,
		result = { kind = "explanation", markdown = "answer" },
	}, function()
		vim.cmd("VantageExplain")
	end)
	local popup_win = ui.last_float_win()

	-- Opening a Question prompt buffer routes through the same ui.open_float
	-- plumbing and overwrites ui.last_float_win/last_float_buf, even though
	-- the explain popup above is still on screen.
	vim.cmd("VantageQuestion")
	local prompt_win = ui.last_float_win()
	assert(prompt_win ~= popup_win, "expected the prompt buffer to become the tracked last float")

	-- Cancel the prompt so only the (still open, no-longer-tracked) explain
	-- popup remains. Cancel is normal-mode-only; the prompt's scheduled
	-- startinsert never lands in a synchronous test, so a single <Esc> here
	-- is already a normal-mode cancel.
	vim.api.nvim_set_current_win(prompt_win)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
	assert(not vim.api.nvim_win_is_valid(prompt_win), "expected the prompt buffer to be cancelled")
	assert(vim.api.nvim_win_is_valid(popup_win), "expected the explain popup to still be open")

	vim.api.nvim_set_current_win(popup_win)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<leader>"', true, false, true), "x", false)

	assert(not vim.api.nvim_win_is_valid(popup_win), "expected promotion to close the explain popup, not whatever ui.last_float_win last pointed at")

	local promoted_win = ui.last_float_win()
	eq(vim.api.nvim_win_get_config(promoted_win).relative, "")
	vim.api.nvim_win_close(promoted_win, true)
end)

test("Promoted output buffer has no statusline hint when ui.keybind_hints is false", function()
	local vantage = require("vantage")
	local ui = require("vantage.ui")

	vantage.setup({ backend = { mode = "development" }, ui = { keybind_hints = false } })
	lua_buffer({ "local a = 1" })

	capture_backend_request({
		ok = true,
		result = { kind = "explanation", markdown = "answer" },
	}, function()
		vim.cmd("VantageExplain")
	end)

	local popup_win = ui.last_float_win()
	vim.api.nvim_set_current_win(popup_win)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<leader>"', true, false, true), "x", false)

	local promoted_win = ui.last_float_win()
	eq(vim.api.nvim_win_get_option(promoted_win, "statusline"), "")

	vim.api.nvim_win_close(promoted_win, true)
end)

test("VantageExplain with ui.output.target buffer shows the close statusline hint directly", function()
	local vantage = require("vantage")
	local ui = require("vantage.ui")

	vantage.setup({ backend = { mode = "development" }, ui = { output = { target = "buffer" } } })
	lua_buffer({ "local a = 1" })

	capture_backend_request({
		ok = true,
		result = { kind = "explanation", markdown = "answer" },
	}, function()
		vim.cmd("VantageExplain")
	end)

	local win = ui.last_float_win()
	eq(vim.api.nvim_win_get_config(win).relative, "")
	eq(vim.api.nvim_win_get_option(win, "statusline"), " close q ")

	vim.api.nvim_win_close(win, true)
end)
