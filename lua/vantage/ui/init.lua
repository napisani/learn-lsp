local hints = require("vantage.ui.hints")
local state = require("vantage.state")
local win_util = require("vantage.ui.window")

local M = {}

local last_buf = nil
local last_win = nil

local function close_last_float()
	if last_win and vim.api.nvim_win_is_valid(last_win) then
		vim.api.nvim_win_close(last_win, true)
	end
end

local function markdown_lines(markdown)
	local lines = vim.split(markdown or "", "\n", { plain = true })
	if #lines == 0 then
		return { "" }
	end
	return lines
end

local function dimension(value, total, fallback, minimum, padding)
	minimum = minimum or 1
	padding = padding or 0
	if type(value) == "number" then
		if value > 0 and value <= 1 then
			return math.max(minimum, math.floor(total * value))
		end
		return math.max(minimum, math.min(math.floor(value), total - padding))
	end
	if type(fallback) == "number" and fallback > 0 and fallback <= 1 then
		return math.max(minimum, math.floor(total * fallback))
	end
	return math.max(minimum, math.min(fallback or total, total - padding))
end

local function output_config()
	local ui = state.config.ui or {}
	return ui.output or {}
end

function M.float_options(opts)
	opts = opts or {}
	local config = vim.tbl_deep_extend("force", output_config(), opts.config or {})
	local columns = vim.o.columns
	local rows = vim.o.lines
	local width = dimension(opts.width or config.width, columns, 0.82, 20, 4)
	local max_height = math.max(1, rows - 6)
	local desired_height = opts.height or config.height
	local height = dimension(desired_height, rows, 0.72, 1, 6)
	if opts.line_count then
		height = math.min(height, math.max(1, opts.line_count))
	end
	height = math.min(height, max_height)
	local row = math.max(0, math.floor((rows - height) / 3))
	local col = math.max(0, math.floor((columns - width) / 2))
	return {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = config.border or "rounded",
	}
end

function M.open_float(buf, opts)
	local win = vim.api.nvim_open_win(buf, opts and opts.enter ~= false, M.float_options(opts))
	last_buf = buf
	last_win = win
	return win
end

local function create_output_buffer(lines, modifiable)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
	vim.api.nvim_buf_set_option(buf, "swapfile", false)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", modifiable)
	return buf
end

local function output_target()
	local config = output_config()
	return config.target or "popup"
end

local function promote_modifiable()
	local config = output_config()
	return config.promote_modifiable == true
end

local function output_actions()
	local config = output_config()
	local actions = config.actions or {}
	return {
		promote = win_util.as_list(actions.promote or '<leader>"'),
		promote_vsplit = win_util.as_list(actions.promote_vsplit or "<leader>%"),
	}
end

--- Binds the close keymap (and, for the popup, the promote keymaps) shared
--- by every output surface, then shows the matching keybind-hint text: a
--- floating-window footer for the popup, a window-local statusline for
--- regular split/vsplit output buffers (nvim_win_set_config's `footer` only
--- applies to floating windows).
---@param buf integer
---@param win integer
---@param opts { floating: boolean, include_promote: boolean? }
local function bind_output_keymaps(buf, win, opts)
	local actions = output_actions()

	vim.keymap.set("n", "q", function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end, { buffer = buf, silent = true, desc = "Close Vantage output" })

	local segments = {
		{ label = "close", key = "q" },
	}

	if opts.include_promote then
		for _, lhs in ipairs(actions.promote) do
			vim.keymap.set("n", lhs, function()
				M.promote(buf, win, "split")
			end, { buffer = buf, silent = true, desc = "Promote to split" })
		end
		for _, lhs in ipairs(actions.promote_vsplit) do
			vim.keymap.set("n", lhs, function()
				M.promote(buf, win, "vsplit")
			end, { buffer = buf, silent = true, desc = "Promote to vsplit" })
		end
		table.insert(segments, { label = "promote", key = actions.promote[1] })
		table.insert(segments, { label = "vsplit", key = actions.promote_vsplit[1] })
	end

	local footer = hints.footer(segments)
	if not footer then
		return
	end
	if opts.floating then
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_set_config(win, { footer = footer, footer_pos = "right" })
		end
	else
		vim.api.nvim_win_set_option(win, "statusline", footer)
	end
end

function M.show_markdown(markdown, opts)
	close_last_float()

	local lines = markdown_lines(markdown)

	local target = output_target()
	if target == "buffer" then
		local buf = create_output_buffer(lines, promote_modifiable())
		local win = win_util.open_in_split(buf, "botright split")
		win_util.apply_readable_options(win, true)
		bind_output_keymaps(buf, win, { floating = false })
		last_buf = buf
		last_win = win
		return buf, win
	elseif target == "buffer_vsplit" then
		local buf = create_output_buffer(lines, promote_modifiable())
		local win = win_util.open_in_split(buf, "botright vsplit")
		win_util.apply_readable_options(win, true)
		bind_output_keymaps(buf, win, { floating = false })
		last_buf = buf
		last_win = win
		return buf, win
	end

	-- Default: popup float
	local buf = create_output_buffer(lines, false)
	local config = output_config()
	local win = M.open_float(buf, vim.tbl_extend("force", opts or {}, { line_count = #lines }))
	win_util.apply_readable_options(win, config.wrap)
	bind_output_keymaps(buf, win, { floating = true, include_promote = true })

	return buf, win
end

--- Promotes a specific output surface (by its own buf/win, not the shared
--- "last shown" state) into a regular split/vsplit buffer. Keymaps bound
--- directly on an output popup call this with their own captured buf/win so
--- promoting one popup can't be derailed by another float (e.g. a Question
--- prompt buffer) having since become the shared last_buf/last_win.
---@param source_buf integer
---@param source_win integer
---@param split_mode "split"|"vsplit"
function M.promote(source_buf, source_win, split_mode)
	if not vim.api.nvim_buf_is_valid(source_buf) then
		vim.notify("Vantage: no output to promote", vim.log.levels.WARN)
		return
	end

	local lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
	local buf = create_output_buffer(lines, promote_modifiable())

	local cmd = split_mode == "vsplit" and "botright vsplit" or "botright split"
	local win = win_util.open_in_split(buf, cmd)
	win_util.apply_readable_options(win, true)
	bind_output_keymaps(buf, win, { floating = false })

	if source_win and vim.api.nvim_win_is_valid(source_win) then
		vim.api.nvim_win_close(source_win, true)
	end

	last_buf = buf
	last_win = win
end

--- Promotes whatever output surface is currently tracked as "last shown".
--- Used by the standalone `:VantageOutputToBuffer`-style command, which has
--- no popup instance of its own to capture a buf/win from.
---@param split_mode "split"|"vsplit"
function M.promote_last_float(split_mode)
	if not last_buf or not vim.api.nvim_buf_is_valid(last_buf) then
		vim.notify("Vantage: no output to promote", vim.log.levels.WARN)
		return
	end
	M.promote(last_buf, last_win, split_mode)
end

function M.last_float_buf()
	return last_buf
end

function M.last_float_win()
	return last_win
end

return M
