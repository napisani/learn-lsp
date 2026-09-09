-- Shared helpers for the Lua suite.
--
-- Kept as plain locals that reference each other directly (lua_buffer ->
-- fresh_buffer -> close_floating_windows), then exported as a table at the
-- bottom. Spec modules localize only the helpers they use.

local function eq(actual, expected)
	assert(vim.deep_equal(actual, expected), "expected " .. vim.inspect(expected) .. " but got " .. vim.inspect(actual))
end

local function close_floating_windows()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_config(win).relative ~= "" then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end
end

local function fresh_buffer()
	close_floating_windows()
	vim.cmd("silent! %bwipeout!")
	vim.cmd("enew!")
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

local function lua_buffer(lines)
	fresh_buffer()
	vim.bo.filetype = "lua"
	vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
end

local function temp_workspace()
	local root = vim.fn.tempname()
	vim.fn.mkdir(root .. "/.git", "p")
	vim.fn.mkdir(root .. "/.vantage", "p")
	return root
end

local function normalized_path(path)
	return ((vim.loop.fs_realpath(path) or vim.fn.fnamemodify(path, ":p")):gsub("/+$", ""))
end

local function set_buffer_path(path)
	vim.api.nvim_buf_set_name(0, path)
end

local function writefile(path, text)
	local fd = assert(vim.loop.fs_open(path, "w", 420))
	assert(vim.loop.fs_write(fd, text, 0))
	vim.loop.fs_close(fd)
end

local function last_float_text()
	local float_buf = require("vantage.ui").last_float_buf()
	if not float_buf or not vim.api.nvim_buf_is_valid(float_buf) then
		return nil
	end

	return table.concat(vim.api.nvim_buf_get_lines(float_buf, 0, -1, false), "\n")
end

local function submit_prompt_buffer(text)
	local ui = require("vantage.ui")
	local buf = ui.last_float_buf()
	local win = ui.last_float_win()
	assert(buf and vim.api.nvim_buf_is_valid(buf), "expected Vantage prompt buffer")
	assert(win and vim.api.nvim_win_is_valid(win), "expected Vantage prompt window")
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
	vim.api.nvim_set_current_win(win)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
end

-- Whether `lhs` is mapped on `buf` in `mode`. The prompt buffer's
-- `startinsert` runs inside vim.schedule() and only takes effect once nvim
-- next reads input, so a synchronous headless test can never observe insert
-- mode -- inspecting the buffer's keymap table asserts the mode-scoping
-- contract directly instead of trying to drive real mode transitions.
local function prompt_buffer_mapped(buf, mode, lhs)
	local want = vim.api.nvim_replace_termcodes(lhs, true, false, true)
	for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
		if vim.api.nvim_replace_termcodes(map.lhs, true, false, true) == want then
			return true
		end
	end
	return false
end

local function toggle_prompt_buffer_runtime()
	local ui = require("vantage.ui")
	local win = ui.last_float_win()
	assert(win and vim.api.nvim_win_is_valid(win), "expected Vantage prompt window")
	vim.api.nvim_set_current_win(win)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-r>", true, false, true), "x", false)
end

local function prompt_buffer_footer_text()
	local ui = require("vantage.ui")
	local win = ui.last_float_win()
	assert(win and vim.api.nvim_win_is_valid(win), "expected Vantage prompt window")
	local footer = vim.api.nvim_win_get_config(win).footer
	return footer and footer[1] and footer[1][1] or nil
end

local function capture_notifications(run)
	local notifications = {}
	local original_notify = vim.notify
	local ok, err = pcall(function()
		vim.notify = function(message)
			table.insert(notifications, message)
		end
		run(notifications)
	end)

	vim.notify = original_notify
	assert(ok, err)
	return notifications
end

local function capture_backend_request(response, run)
	local backend = require("vantage.backend")
	local original_request = backend.request
	local captured = {}
	local ok, err = pcall(function()
		backend.request = function(method, params, callback)
			captured.method = method
			captured.params = params
			if response and callback then
				callback(response)
			end
			return "captured-request"
		end
		run(captured)
	end)

	backend.request = original_request
	assert(ok, err)
	return captured
end

local function with_ui_input(input_fn, run)
	local original_input = vim.ui.input
	local ok, err = pcall(function()
		vim.ui.input = input_fn
		run()
	end)

	vim.ui.input = original_input
	assert(ok, err)
end

local function with_fn_input(input_fn, run)
	local original_input = vim.fn.input
	local ok, err = pcall(function()
		vim.fn.input = input_fn
		run()
	end)

	vim.fn.input = original_input
	assert(ok, err)
end


return {
	eq = eq,
	close_floating_windows = close_floating_windows,
	fresh_buffer = fresh_buffer,
	lua_buffer = lua_buffer,
	temp_workspace = temp_workspace,
	normalized_path = normalized_path,
	set_buffer_path = set_buffer_path,
	writefile = writefile,
	last_float_text = last_float_text,
	submit_prompt_buffer = submit_prompt_buffer,
	prompt_buffer_mapped = prompt_buffer_mapped,
	toggle_prompt_buffer_runtime = toggle_prompt_buffer_runtime,
	prompt_buffer_footer_text = prompt_buffer_footer_text,
	capture_notifications = capture_notifications,
	capture_backend_request = capture_backend_request,
	with_ui_input = with_ui_input,
	with_fn_input = with_fn_input,
}
