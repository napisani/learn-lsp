-- the floating prompt buffer, vantage.prompt, and format_reference
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq
local lua_buffer = helpers.lua_buffer
local temp_workspace = helpers.temp_workspace
local writefile = helpers.writefile
local submit_prompt_buffer = helpers.submit_prompt_buffer
local prompt_buffer_mapped = helpers.prompt_buffer_mapped
local toggle_prompt_buffer_runtime = helpers.toggle_prompt_buffer_runtime
local prompt_buffer_footer_text = helpers.prompt_buffer_footer_text
local capture_backend_request = helpers.capture_backend_request

test("VantageQuestion prompt buffer footer defaults to the checked agent runtime with keybind hints", function()
	local vantage = require("vantage")

	capture_backend_request({
		ok = true,
		result = { kind = "explanation", markdown = "answer" },
	}, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({ "local a = 1" })

		vim.cmd("VantageQuestion")
		eq(prompt_buffer_footer_text(), " [x] agent <C-r>  submit <CR> ")
		submit_prompt_buffer("what is a?")
	end)
end)

test("VantageQuestion prompt buffer footer starts unchecked with runtime=completion", function()
	local vantage = require("vantage")

	capture_backend_request({
		ok = true,
		result = { kind = "explanation", markdown = "answer" },
	}, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({ "local a = 1" })

		vim.cmd("VantageQuestion runtime=completion")
		eq(prompt_buffer_footer_text(), " [ ] agent <C-r>  submit <CR> ")
		submit_prompt_buffer("what is a?")
	end)
end)

test("VantageQuestion prompt buffer toggle_runtime keymap flips the runtime sent to the backend", function()
	local vantage = require("vantage")

	local captured = capture_backend_request({
		ok = true,
		result = { kind = "explanation", markdown = "answer" },
	}, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({ "local a = 1" })

		vim.cmd("VantageQuestion")
		eq(prompt_buffer_footer_text(), " [x] agent <C-r>  submit <CR> ")
		toggle_prompt_buffer_runtime()
		eq(prompt_buffer_footer_text(), " [ ] agent <C-r>  submit <CR> ")
		submit_prompt_buffer("what is a?")
	end)

	eq(captured.params.runtime, "completion")
end)

test("VantageQuestion prompt buffer toggle_runtime keymap is configurable", function()
	local vantage = require("vantage")

	local captured = capture_backend_request({
		ok = true,
		result = { kind = "explanation", markdown = "answer" },
	}, function()
		vantage.setup({
			backend = { mode = "development" },
			ui = { prompt = { keymaps = { toggle_runtime = "<C-t>" } } },
		})
		lua_buffer({ "local a = 1" })

		vim.cmd("VantageQuestion")
		local ui = require("vantage.ui")
		local win = ui.last_float_win()
		vim.api.nvim_set_current_win(win)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-t>", true, false, true), "x", false)
		eq(prompt_buffer_footer_text(), " [ ] agent <C-t>  submit <CR> ")
		submit_prompt_buffer("what is a?")
	end)

	eq(captured.params.runtime, "completion")
end)

test("VantageQuestion prompt buffer footer hides keybinds when ui.keybind_hints is false", function()
	local vantage = require("vantage")

	capture_backend_request({
		ok = true,
		result = { kind = "explanation", markdown = "answer" },
	}, function()
		vantage.setup({ backend = { mode = "development" }, ui = { keybind_hints = false } })
		lua_buffer({ "local a = 1" })

		vim.cmd("VantageQuestion")
		eq(prompt_buffer_footer_text(), " [x] agent ")
		submit_prompt_buffer("what is a?")
	end)
end)

test("vantage.format_reference emits the @ref syntax the prompt buffer parses", function()
	local vantage = require("vantage")

	eq(vantage.format_reference({ path = "lua/x.lua" }), "@lua/x.lua")
	eq(vantage.format_reference({ path = "lua/x.lua", start_line = 12, end_line = 40 }), "@lua/x.lua lines 12-40")
	-- Equal bounds collapse to the singular form rather than "lines 12-12".
	eq(vantage.format_reference({ path = "lua/x.lua", start_line = 12, end_line = 12 }), "@lua/x.lua line 12")
	-- A lone bound is not a range.
	eq(vantage.format_reference({ path = "lua/x.lua", start_line = 12 }), "@lua/x.lua")
	eq(vantage.format_reference({ path = "./lua/x.lua" }), "@lua/x.lua")
	eq(vantage.format_reference({ path = "" }), nil)
	eq(vantage.format_reference({}), nil)
	eq(vantage.format_reference(nil), nil)
end)

test("vantage.prompt collects multi-line input and expands references", function()
	local vantage = require("vantage")
	local root = temp_workspace()
	writefile(root .. "/target.lua", "return 1\n")

	vantage.setup({ backend = { mode = "development" } })
	lua_buffer({ "local a = 1" })

	local submitted, submitted_runtime
	vantage.prompt({
		kind = "memo",
		params = { workspaceRoot = root },
		on_submit = function(text, runtime)
			submitted = text
			submitted_runtime = runtime
		end,
	})

	submit_prompt_buffer("look at @target.lua\nsecond line")

	assert(submitted, "expected on_submit to receive the prompt text")
	assert(submitted:match("look at @target.lua"), submitted)
	assert(submitted:match("second line"), submitted)
	-- Reference expansion resolved the @ref against params.workspaceRoot.
	assert(submitted:match("## Vantage Prompt References"), submitted)
	assert(submitted:match("target%.lua"), submitted)
	eq(submitted_runtime, "agent")
end)

test("vantage.prompt does not invoke on_submit when cancelled", function()
	local vantage = require("vantage")
	local ui = require("vantage.ui")

	vantage.setup({ backend = { mode = "development" } })
	lua_buffer({ "local a = 1" })

	local called = false
	vantage.prompt({
		on_submit = function()
			called = true
		end,
	})

	local win = ui.last_float_win()
	vim.api.nvim_set_current_win(win)
	vim.api.nvim_feedkeys("q", "x", false)

	assert(not vim.api.nvim_win_is_valid(win), "expected the prompt to close")
	assert(not called, "expected on_submit not to run on cancel")
end)

test("vantage.prompt can show the runtime toggle and report the chosen runtime", function()
	local vantage = require("vantage")

	vantage.setup({ backend = { mode = "development" } })
	lua_buffer({ "local a = 1" })

	local submitted_runtime
	vantage.prompt({
		runtime = "agent",
		show_runtime_toggle = true,
		on_submit = function(_, runtime)
			submitted_runtime = runtime
		end,
	})

	eq(prompt_buffer_footer_text(), " [x] agent <C-r>  submit <CR> ")
	toggle_prompt_buffer_runtime()
	submit_prompt_buffer("compose this")

	eq(submitted_runtime, "completion")
end)

test("vantage.prompt renders an optional title on the float border", function()
	local vantage = require("vantage")
	local ui = require("vantage.ui")

	vantage.setup({ backend = { mode = "development" } })
	lua_buffer({ "local a = 1" })

	vantage.prompt({ title = "Instruction", on_submit = function() end })

	local config = vim.api.nvim_win_get_config(ui.last_float_win())
	eq(config.title[1][1], " Instruction ")
	-- Setting a title must not clear the keybind-hint footer.
	eq(config.footer[1][1], " submit <CR> ")

	vim.api.nvim_win_close(ui.last_float_win(), true)
end)

test("Prompt buffer scopes cancel/close to normal mode so insert-mode <Esc> is not stolen", function()
	local vantage = require("vantage")
	local ui = require("vantage.ui")

	vantage.setup({ backend = { mode = "development" } })
	lua_buffer({ "local a = 1" })

	vim.cmd("VantageQuestion")
	local buf = ui.last_float_buf()

	-- The bug: <Esc> was bound in insert mode too, so it closed the float
	-- instead of leaving insert mode -- making normal mode, and every
	-- normal-mode-only keymap in this buffer, unreachable.
	assert(not prompt_buffer_mapped(buf, "i", "<Esc>"), "insert-mode <Esc> must stay unmapped")
	assert(prompt_buffer_mapped(buf, "n", "<Esc>"), "normal-mode <Esc> should cancel")

	assert(not prompt_buffer_mapped(buf, "i", "q"), "q must not be mapped in insert mode")
	assert(prompt_buffer_mapped(buf, "n", "q"), "normal-mode q should abort")

	-- submit stays available from both modes; it is not an <Esc>-like key.
	assert(prompt_buffer_mapped(buf, "i", "<CR>"), "insert-mode <CR> should submit")
	assert(prompt_buffer_mapped(buf, "n", "<CR>"), "normal-mode <CR> should submit")

	vim.api.nvim_win_close(ui.last_float_win(), true)
end)

test("Prompt buffer cancels on <Esc> from normal mode", function()
	local vantage = require("vantage")
	local ui = require("vantage.ui")

	vantage.setup({ backend = { mode = "development" } })
	lua_buffer({ "local a = 1" })

	vim.cmd("VantageQuestion")
	local win = ui.last_float_win()
	vim.api.nvim_set_current_win(win)

	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)

	assert(not vim.api.nvim_win_is_valid(win), "expected normal-mode <Esc> to cancel the prompt")
end)

test("Prompt buffer aborts with q in normal mode", function()
	local vantage = require("vantage")
	local ui = require("vantage.ui")

	vantage.setup({ backend = { mode = "development" } })
	lua_buffer({ "local a = 1" })

	vim.cmd("VantageQuestion")
	local win = ui.last_float_win()
	vim.api.nvim_set_current_win(win)

	vim.api.nvim_feedkeys("q", "x", false)

	assert(not vim.api.nvim_win_is_valid(win), "expected q in normal mode to abort the prompt")
end)

test("Prompt buffer close keymap is configurable", function()
	local vantage = require("vantage")
	local ui = require("vantage.ui")

	vantage.setup({
		backend = { mode = "development" },
		ui = { prompt = { keymaps = { close = "Q" } } },
	})
	lua_buffer({ "local a = 1" })

	vim.cmd("VantageQuestion")
	local win = ui.last_float_win()
	local buf = ui.last_float_buf()
	assert(prompt_buffer_mapped(buf, "n", "Q"), "expected the configured close key to be mapped")
	assert(not prompt_buffer_mapped(buf, "n", "q"), "expected the default close key to be replaced")

	vim.api.nvim_set_current_win(win)
	vim.api.nvim_feedkeys("Q", "x", false)

	assert(not vim.api.nvim_win_is_valid(win), "expected the configured close key to abort the prompt")
end)

test("VantageEdit prompt buffer offers the runtime toggle", function()
	local vantage = require("vantage")

	vantage.setup({ backend = { mode = "development" } })
	lua_buffer({ "local a = 1" })

	vim.cmd("VantageEdit")
	-- Edit accepts a runtime now, so it gets the same switch question has.
	eq(prompt_buffer_footer_text(), " [x] agent <C-r>  submit <CR> ")
	local ui = require("vantage.ui")
	vim.api.nvim_win_close(ui.last_float_win(), true)
end)

test("VantageEdit prompt buffer reflects a configured completion runtime", function()
	local vantage = require("vantage")

	vantage.setup({ backend = { mode = "development" }, commands = { edit = { runtime = "completion" } } })
	lua_buffer({ "local a = 1" })

	vim.cmd("VantageEdit")
	eq(prompt_buffer_footer_text(), " [ ] agent <C-r>  submit <CR> ")
	local ui = require("vantage.ui")
	vim.api.nvim_win_close(ui.last_float_win(), true)
end)

test("VantageEdit prompt buffer keeps the runtime checkbox when hints are off", function()
	local vantage = require("vantage")

	vantage.setup({ backend = { mode = "development" }, ui = { keybind_hints = false } })
	lua_buffer({ "local a = 1" })

	vim.cmd("VantageEdit")
	-- A checkbox carries state, not just a hint, so it survives keybind_hints
	-- being off -- only its key is dropped. Same rule as question.
	eq(prompt_buffer_footer_text(), " [x] agent ")
	local ui = require("vantage.ui")
	vim.api.nvim_win_close(ui.last_float_win(), true)
end)

test("VantageEdit prompt buffer binds the runtime toggle key", function()
	local vantage = require("vantage")

	vantage.setup({ backend = { mode = "development" } })
	lua_buffer({ "local a = 1" })

	vim.cmd("VantageEdit")
	local buf = vim.api.nvim_get_current_buf()
	local found = false
	for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
		if (map.desc or ""):match("Toggle Vantage prompt runtime") then
			found = true
		end
	end
	assert(found, "expected the runtime toggle to be bound in the edit prompt buffer")
	local ui = require("vantage.ui")
	vim.api.nvim_win_close(ui.last_float_win(), true)
end)
