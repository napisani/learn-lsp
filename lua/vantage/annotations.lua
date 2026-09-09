local M = {}

local namespace = vim.api.nvim_create_namespace("vantage_annotations")

function M.is_enabled(bufnr)
	return #M.current_marks(bufnr or 0) > 0
end

function M.clear(bufnr)
	vim.api.nvim_buf_clear_namespace(bufnr or 0, namespace, 0, -1)
end

-- Clear annotation extmarks from every loaded buffer. Walkthrough annotations
-- span multiple buffers, so a single-buffer clear is not enough.
function M.clear_all()
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) then
			vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
		end
	end
end

local function mark_position(annotation)
	local line = 0
	local character = 0
	if annotation.range then
		if annotation.range.startLine then
			line = annotation.range.startLine
		end
		if annotation.range.startCharacter then
			character = annotation.range.startCharacter
		end
	end
	return math.max(0, line - 1), math.max(0, character - 1)
end

local function remove_existing_at(bufnr, line, character)
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, {})) do
		if mark[2] == line and mark[3] == character then
			vim.api.nvim_buf_del_extmark(bufnr, namespace, mark[1])
		end
	end
end

local function annotation_width()
	local ok, width = pcall(vim.api.nvim_win_get_width, 0)
	if not ok or type(width) ~= "number" then
		width = vim.o.columns
	end
	return math.max(24, width - 6)
end

local function append_wrapped_word(lines, word, width)
	while #word > width do
		table.insert(lines, word:sub(1, width))
		word = word:sub(width + 1)
	end
	return word
end

local function wrap_paragraph(paragraph, width)
	if paragraph == "" then
		return { "" }
	end

	local lines = {}
	local current = ""
	for word in paragraph:gmatch("%S+") do
		if current == "" then
			current = append_wrapped_word(lines, word, width)
		elseif #current + 1 + #word <= width then
			current = current .. " " .. word
		else
			table.insert(lines, current)
			current = append_wrapped_word(lines, word, width)
		end
	end

	if current ~= "" then
		table.insert(lines, current)
	end
	if #lines == 0 then
		table.insert(lines, paragraph)
	end
	return lines
end

local function wrap_text(text)
	local width = annotation_width()
	local wrapped = {}
	for paragraph in ((text or "") .. "\n"):gmatch("(.-)\n") do
		for _, line in ipairs(wrap_paragraph(paragraph, width)) do
			table.insert(wrapped, line)
		end
	end
	return wrapped
end

local function virt_lines(annotation)
	local highlight = annotation.severity == "warning" and "WarningMsg" or "Comment"
	local lines = {}
	for _, line in ipairs(wrap_text(annotation.text)) do
		table.insert(lines, { { line, highlight } })
	end
	return lines
end

function M.render(bufnr, annotations)
	bufnr = bufnr or 0
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local rendered = 0

	for _, annotation in ipairs(annotations or {}) do
		local line, character = mark_position(annotation)

		if type(line) == "number" and line >= 0 and line < line_count and annotation.text and annotation.text ~= "" then
			remove_existing_at(bufnr, line, character)
			vim.api.nvim_buf_set_extmark(bufnr, namespace, line, character, {
				virt_lines = virt_lines(annotation),
				virt_lines_above = true,
			})
			rendered = rendered + 1
		end
	end

	return rendered
end

function M.current_marks(bufnr)
	return vim.api.nvim_buf_get_extmarks(bufnr or 0, namespace, 0, -1, { details = true })
end

return M
