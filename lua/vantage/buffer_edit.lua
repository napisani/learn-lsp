-- Writing model-produced text into a buffer.
--
-- Line-splitting helpers live in `vantage.search_replace` so the two apply paths
-- cannot disagree about trailing-newline rules -- they previously had
-- same-named locals with different edge cases, which is how a wrong assumption
-- travels when code moves between them.
local search_replace = require("vantage.search_replace")

local M = {}

function M.apply(bufnr, range, replacement_text)
	if type(range) ~= "table" then
		return nil, "Missing edit range."
	end
	-- The request is async: the buffer can be wiped while the model is thinking.
	-- Without this, nvim_buf_line_count raises inside the response callback,
	-- after the tracker token was already consumed -- so the user saw a bare Lua
	-- error and the tracker recorded neither success nor failure.
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil, "The buffer this edit was requested for no longer exists."
	end
	if type(replacement_text) ~= "string" or replacement_text:match("%S") == nil then
		return nil, "Agent returned an empty edit."
	end

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local start_line = range.startLine
	local end_line = range.endLine
	if type(start_line) ~= "number" or type(end_line) ~= "number" or start_line < 1 or end_line < start_line then
		return nil, "Invalid edit range."
	end
	if start_line > line_count then
		return nil, "Edit range starts outside the buffer."
	end

	local start_index = start_line - 1
	local end_index = math.min(end_line, line_count)
	local lines = search_replace.replacement_lines_trimmed(replacement_text)
	vim.api.nvim_buf_set_lines(bufnr, start_index, end_index, false, lines)
	return {
		replaced_start_line = start_line,
		replaced_end_line = end_line,
		line_count = #lines,
	}
end

---Starts a new undo entry, so the edit cannot merge into whatever change came
---before it.
---
---Setting 'undolevels' to itself is Vim's documented undo-break
---(`:help undo-break`). It is required rather than decorative: Vim only closes
---an undo block when it next waits for input, so a plugin writing on the same
---or even a later tick can land in the *user's* previous undo entry -- and then
---one `u` reverts their work along with ours.
---@param bufnr integer
local function break_undo(bufnr)
	pcall(function()
		vim.bo[bufnr].undolevels = vim.bo[bufnr].undolevels
	end)
end

---Applies hunks already resolved by `vantage.search_replace`.
---
---Written as a **single** `nvim_buf_set_lines` over the affected span, which is
---what makes the whole edit one undo entry. That matters more than usual here:
---edits apply straight to the buffer, so `u` is the entire safety net, and an
---edit that undoes one hunk at a time is worse than useless when three hunks
---landed together.
---
---One call rather than one per hunk because `undojoin` does not reliably merge
---API-driven changes -- three `set_lines` calls produce three undo entries even
---with `undojoin` between them. Spanning only first-changed to last-changed
---line, rather than the whole buffer, keeps extmarks and folds outside the span
---intact.
---@param bufnr integer
---@param resolved ResolvedHunk[]
---@return integer applied how many hunks were written
function M.apply_hunks(bufnr, resolved)
	if type(resolved) ~= "table" or #resolved == 0 then
		return 0
	end
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local ordered = {}
	for _, hunk in ipairs(resolved) do
		if type(hunk.start_line) == "number" and hunk.start_line >= 1 and hunk.start_line <= line_count then
			table.insert(ordered, hunk)
		end
	end
	if #ordered == 0 then
		return 0
	end

	table.sort(ordered, function(a, b)
		return a.start_line < b.start_line
	end)

	local span_start = ordered[1].start_line
	local span_end = span_start
	for _, hunk in ipairs(ordered) do
		span_end = math.max(span_end, math.min(hunk.end_line, line_count))
	end

	local original = vim.api.nvim_buf_get_lines(bufnr, span_start - 1, span_end, false)
	local rebuilt = {}
	local cursor = span_start
	for _, hunk in ipairs(ordered) do
		-- Untouched lines between the previous hunk and this one.
		for line = cursor, hunk.start_line - 1 do
			table.insert(rebuilt, original[line - span_start + 1])
		end
		for _, replacement in ipairs(hunk.lines or {}) do
			table.insert(rebuilt, replacement)
		end
		cursor = math.min(hunk.end_line, line_count) + 1
	end
	for line = cursor, span_end do
		table.insert(rebuilt, original[line - span_start + 1])
	end

	break_undo(bufnr)
	vim.api.nvim_buf_set_lines(bufnr, span_start - 1, span_end, false, rebuilt)
	return #ordered
end

return M
