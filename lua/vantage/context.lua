local state = require("vantage.state")
local agent_context = require("vantage.agent_context")
local visual = require("vantage.visual")
local M = {}

local function cursor()
	local pos = vim.api.nvim_win_get_cursor(0)
	return { line = pos[1], character = pos[2] + 1 }
end

local function range_for_lines(start_line, end_line, lines)
	local last_line = lines[#lines] or ""
	return {
		startLine = start_line,
		startCharacter = 1,
		endLine = end_line,
		endCharacter = math.max(1, #last_line),
	}
end

function M.visible()
	local start_line = vim.fn.line("w0")
	local end_line = vim.fn.line("w$")
	local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
	local snapshot = agent_context.snapshot()

	return {
		workspaceRoot = snapshot.workspace_root,
		filePath = vim.api.nvim_buf_get_name(0),
		language = vim.bo.filetype ~= "" and vim.bo.filetype or "text",
		text = table.concat(lines, "\n"),
		cursor = cursor(),
		visibleRange = range_for_lines(start_line, end_line, lines),
		lens = state.get_lens(),
		agentContext = snapshot.context,
	}
end

function M.buffer()
	local line_count = vim.api.nvim_buf_line_count(0)
	local lines = vim.api.nvim_buf_get_lines(0, 0, line_count, false)
	local snapshot = agent_context.snapshot()

	return {
		workspaceRoot = snapshot.workspace_root,
		filePath = vim.api.nvim_buf_get_name(0),
		language = vim.bo.filetype ~= "" and vim.bo.filetype or "text",
		text = table.concat(lines, "\n"),
		cursor = cursor(),
		visibleRange = range_for_lines(1, math.max(1, line_count), lines),
		lens = state.get_lens(),
		agentContext = snapshot.context,
	}
end

function M.line_range(start_line, end_line)
	local line_count = vim.api.nvim_buf_line_count(0)
	local first_line = math.max(1, math.min(start_line, end_line))
	local last_line = math.min(line_count, math.max(start_line, end_line))
	local lines = vim.api.nvim_buf_get_lines(0, first_line - 1, last_line, false)
	local text = table.concat(lines, "\n")
	local range = range_for_lines(first_line, last_line, lines)
	local snapshot = agent_context.snapshot()

	return {
		workspaceRoot = snapshot.workspace_root,
		filePath = vim.api.nvim_buf_get_name(0),
		language = vim.bo.filetype ~= "" and vim.bo.filetype or "text",
		text = text,
		cursor = cursor(),
		visibleRange = range,
		range = range,
		selectedText = text,
		lens = state.get_lens(),
		agentContext = snapshot.context,
	}
end

function M.current_line()
	local pos = cursor()
	return M.line_range(pos.line, pos.line)
end

---The range the caller explicitly asked for, or has selected right now.
---Resolution order:
---  1. an explicit command range -- `:'<,'>Vantage*` / `:10,20Vantage*`, where
---     Vim has already committed line1/line2 before the callback runs
---  2. a live visual selection -- a keymap bound to a plain Lua function, which
---     never commits the '< / '> marks the explicit path relies on
---Returns nil when neither applies, so callers can fall back to their own
---default scope.
---@param opts table? a user-command callback's opts (range/line1/line2)
---@return table? params
function M.selected_range(opts)
	if opts and type(opts.range) == "number" and opts.range > 0 then
		local params = M.line_range(opts.line1, opts.line2)
		params.selectionSource = "range"
		return params
	end

	local start_line, end_line = visual.live_range()
	if start_line and end_line then
		local params = M.line_range(start_line, end_line)
		params.selectionSource = "visual"
		return params
	end

	return nil
end

---`selected_range`, falling back to the cursor line.
---
---The returned params carry `selectionSource`, which is the only way a caller
---can tell a real one-line selection from a cursor-line fallback -- both
---populate `range` and `selectedText` identically. Integrations rendering a
---"Selection" block should check it rather than threading their own mode flag.
---@param opts table? a user-command callback's opts (range/line1/line2)
---@return table params params.selectionSource is "range" | "visual" | "cursor"
function M.scoped(opts)
	local selected = M.selected_range(opts)
	if selected then
		return selected
	end

	local params = M.current_line()
	params.selectionSource = "cursor"
	return params
end

return M
