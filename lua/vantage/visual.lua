-- Visual-mode selection detection.
--
-- Exists so a command invoked from a keymap bound to a plain Lua function in
-- visual mode still sees the user's selection. Commands invoked as
-- `:'<,'>Vantage*` don't need this -- Vim commits the '< / '> marks before
-- running a ":"-range command -- but a Lua callback goes through none of the
-- events that commit those marks.
local M = {}

-- mode() strings that mean a visual selection is live right now.
-- "\22" is <C-v> (blockwise).
local VISUAL_MODES = { v = true, V = true, ["\22"] = true }

---Whether Neovim is in a visual mode right now.
---@return boolean
function M.in_visual_mode()
	return VISUAL_MODES[vim.fn.mode()] == true
end

---The line range of the visual selection that is live right now.
---
---Deliberately reads the live anchor ("v") and cursor (".") positions rather
---than the '< / '> marks. Those marks are only committed when visual mode is
---formally exited (Esc, an operator, or a ":"-range command); a keymap bound to
---a plain Lua function triggers none of those, so at call time '< / '> still
---hold whatever was left over from the *previous* properly-closed selection.
---Reading them would silently capture stale, often off-by-one-selection text.
---
---Returns nil unless a selection is live. There is deliberately no '< / '>
---fallback: outside visual mode those marks are indistinguishable from a stale
---leftover, so falling back to them would make every normal-mode invocation
---silently reuse the last selection instead of the cursor line.
---
---Only lines are returned. `context.line_range` derives its own columns from
---the lines it fetches, so the raw-column correction that distinguishing
---charwise from linewise would otherwise require is unnecessary here.
---@return integer? start_line
---@return integer? end_line
function M.live_range()
	if not M.in_visual_mode() then
		return nil
	end

	local anchor = vim.fn.line("v")
	local cursor = vim.fn.line(".")
	if anchor < 1 or cursor < 1 then
		return nil
	end

	if anchor > cursor then
		anchor, cursor = cursor, anchor
	end

	return anchor, cursor
end

return M
