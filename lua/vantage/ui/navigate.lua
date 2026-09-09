-- Default presentation for monitor mode: open the changed file in the current
-- window as an ordinary buffer.
--
-- Deliberately native, and deliberately keymap-free. Opening a file is already
-- a Vim "jump", so the position you were at lands in the jumplist and
-- <C-o>/<C-i> walk the trail of recent edits with no bindings of our own. This
-- replaced a floating window with its own cycle keys: the editor already had
-- the mechanism, and reimplementing it meant shadowing the user's arrow keys
-- and holding a real file buffer in a window that must never take focus.
local M = {}

---Whether changing the current buffer right now would be hostile.
---
---Only normal mode qualifies. Swapping the buffer out from under someone who is
---typing, selecting, or answering a prompt would send their next keystrokes into
---a file the agent is editing. The entry still reaches the ring either way, so
---`vantage.monitor_entries()` and anything built on it still sees the file.
---@return boolean
function M.can_navigate()
	return vim.fn.mode() == "n"
end

---Places the cursor on the changed line, when there is one and it exists.
---@param line integer?
local function place(line)
	if not line then
		return
	end
	local count = vim.api.nvim_buf_line_count(0)
	pcall(vim.api.nvim_win_set_cursor, 0, { math.min(line, count), 0 })
end

---Opens `context.path`, or reports why it did not.
---
---This is monitor mode's default renderer. A `monitor.render` in config replaces
---it wholesale and receives the same context table, which is how a diff view
---stays config-supplied and Vantage never names a diff plugin.
---@param context MonitorRenderContext
---@return boolean navigated
function M.open(context)
	if not context or not context.path then
		return false
	end

	if context.deleted then
		-- Nothing to open: `:edit` on a missing path would create an empty
		-- buffer indistinguishable from a file whose contents were cleared.
		vim.notify("Vantage monitor: deleted " .. vim.fn.fnamemodify(context.path, ":."), vim.log.levels.INFO)
		return false
	end

	if not M.can_navigate() then
		return false
	end

	local current = vim.api.nvim_get_current_buf()

	-- Already looking at it with unsaved work: `:edit` would reload and discard
	-- the user's edits, which is never worth a refresh. Say so instead.
	if vim.fn.bufnr(context.path) == current and vim.bo[current].modified then
		vim.notify(
			"Vantage monitor: " .. vim.fn.fnamemodify(context.path, ":.") .. " changed on disk (buffer modified)",
			vim.log.levels.WARN
		)
		return false
	end

	-- Plain `:edit`, deliberately without `!`: it records the jump that makes
	-- <C-o> work, reloads in place when the file is already current, and
	-- refuses to discard unsaved changes in the target.
	local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(context.path))
	if not ok then
		vim.notify("Vantage monitor: could not open " .. context.path .. " (" .. tostring(err) .. ")", vim.log.levels.WARN)
		return false
	end

	place(context.line)
	return true
end

return M
