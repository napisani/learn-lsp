-- Shared window/buffer plumbing for Vantage's UI surfaces.
--
-- The surfaces themselves are genuinely different (an ephemeral prompt float, a
-- persistent composition split, an output popup, a polling session-output
-- float), but the plumbing under them is not. Each one previously carried its
-- own copy of `as_list`, its own keymap-config accessor, and its own
-- split/readable-window setup, so a fix in one silently skipped the others --
-- the composition split, for instance, was missing `breakindent` that every
-- other surface set.
local M = {}

---Normalizes a keymap config value into a list of left-hand sides. Accepts a
---single string for convenience, a list for multiple bindings, and treats
---anything else (including the empty string) as "unbound".
---@param value string|string[]|nil
---@return string[]
function M.as_list(value)
	if type(value) == "table" then
		return value
	end
	if type(value) == "string" and value ~= "" then
		return { value }
	end
	return {}
end

---Resolves a surface's keymaps from config, normalizing each entry to a list.
---
---`defaults` supplies the fallback per action for callers that can be reached
---before `setup()` runs. Where `state`'s own `default_config()` already carries
---the value, prefer passing the config table straight through and leaving
---`defaults` empty rather than restating the default here.
---@param configured table? the `keymaps` table for this surface
---@param defaults table<string, string|string[]>? per-action fallbacks
---@return table<string, string[]>
function M.keymaps(configured, defaults)
	configured = configured or {}
	defaults = defaults or {}

	local resolved = {}
	for action, fallback in pairs(defaults) do
		resolved[action] = M.as_list(configured[action] or fallback)
	end
	for action, value in pairs(configured) do
		if resolved[action] == nil then
			resolved[action] = M.as_list(value)
		end
	end
	return resolved
end

---Window options that make prose and markdown readable. Applied to every
---Vantage surface so they cannot drift apart.
---@param win integer
---@param wrap boolean? defaults to true
function M.apply_readable_options(win, wrap)
	vim.wo[win].wrap = wrap ~= false
	vim.wo[win].linebreak = true
	vim.wo[win].breakindent = true
end

---Opens `buf` in a split and returns the new window.
---@param buf integer
---@param split_cmd string e.g. "botright split", "rightbelow split"
---@return integer win
function M.open_in_split(buf, split_cmd)
	vim.cmd(split_cmd)
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	return win
end

---Renders a keybinding hint into a window's statusline, the split-window
---equivalent of a float's border footer. No-ops when hints are disabled, so
---callers do not need to check.
---@param win integer
---@param segments table[] hint segments, as accepted by `vantage.ui.hints.footer`
function M.apply_statusline_hint(win, segments)
	local hint = require("vantage.ui.hints").footer(segments)
	if hint and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_set_option_value("statusline", hint, { win = win })
	end
end

---A buffer's entire contents as one string.
---@param buf integer
---@return string
function M.buffer_text(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return ""
	end
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

---Replaces a buffer's entire contents and puts the cursor at the end.
---@param buf integer
---@param text string
function M.replace_buffer(buf, text)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.bo[buf].modifiable = true
	local lines = vim.split(text, "\n", { plain = true })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	local win = M.window_in_current_tabpage(buf)
	if win then
		vim.api.nvim_win_set_cursor(win, { #lines, #(lines[#lines] or "") })
	end
end

---The window currently displaying `buf` in the *current tabpage*, if any.
---
---Deliberately tabpage-scoped: `nvim_list_wins()` spans every tabpage, so a
---global search would focus a window in another tab, or reuse an off-screen one
---so the user sees nothing happen in the tab they are working in.
---@param buf integer
---@return integer? win
function M.window_in_current_tabpage(buf)
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_get_buf(win) == buf then
			return win
		end
	end
	return nil
end

return M
