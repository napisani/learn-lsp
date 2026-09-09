local state = require("vantage.state")
local ui = require("vantage.ui")

local M = {}

local function log_path()
	local debug = state.config and state.config.debug
	return debug and debug.log_path
end

local function read_log(path)
	local fd, open_err = vim.loop.fs_open(path, "r", 438)
	if not fd then
		return nil, open_err or "failed to open log file"
	end
	local stat = vim.loop.fs_fstat(fd)
	local size = stat and stat.size or 0
	if size == 0 then
		vim.loop.fs_close(fd)
		return "", nil
	end
	local data, read_err = vim.loop.fs_read(fd, size, 0)
	vim.loop.fs_close(fd)
	if not data then
		return nil, read_err or "failed to read log file"
	end
	return data, nil
end

function M.open()
	local path = log_path()
	if not path then
		vim.notify("Vantage: debug.log_path not configured. Set debug.log_path in setup() or vim.g.vantage_debug_log_path.", vim.log.levels.WARN)
		return
	end

	local content, read_err = read_log(path)
	if not content then
		vim.notify("Vantage: " .. tostring(read_err), vim.log.levels.ERROR)
		return
	end

	if content == "" then
		content = "(empty log file)"
	end

	local lines = vim.split(content, "\n", { plain = true })
	-- Remove trailing empty line from final newline
	if lines[#lines] == "" then
		table.remove(lines)
	end
	if #lines == 0 then
		lines = { "(empty log file)" }
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(buf, "filetype", "json")
	vim.api.nvim_buf_set_option(buf, "swapfile", false)
	vim.api.nvim_buf_set_name(buf, "vantage-debug-log")
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)

	local float_buf, float_win = ui.show_markdown(table.concat(lines, "\n"), { enter = true })

	-- Auto-refresh on CursorHold
	vim.api.nvim_create_autocmd("CursorHold", {
		buffer = float_buf,
		callback = function()
			if not vim.api.nvim_buf_is_valid(float_buf) then
				return
			end
			local updated, err = read_log(path)
			if not updated then
				return
			end
			if updated == "" then
				updated = "(empty log file)"
			end
			local updated_lines = vim.split(updated, "\n", { plain = true })
			if updated_lines[#updated_lines] == "" then
				table.remove(updated_lines)
			end
			if #updated_lines == 0 then
				updated_lines = { "(empty log file)" }
			end
			vim.api.nvim_buf_set_option(float_buf, "modifiable", true)
			vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, updated_lines)
			vim.api.nvim_buf_set_option(float_buf, "modifiable", false)
		end,
	})
end

return M
