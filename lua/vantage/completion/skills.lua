local skill_cache = require("vantage.skill_cache")

local M = {}

local function is_prompt_buffer(bufnr)
	local ok, value = pcall(vim.api.nvim_buf_get_var, bufnr or vim.api.nvim_get_current_buf(), "vantage_prompt_buffer")
	return ok and value == true
end

local function line_before_cursor(ctx)
	local bufnr = ctx and ctx.bufnr or vim.api.nvim_get_current_buf()
	local row, col, line
	if ctx and type(ctx.cursor) == "table" then
		if ctx.cursor.line then
			row = ctx.cursor.line
			col = ctx.cursor.character
		else
			row = (ctx.cursor[1] or 1) - 1
			col = ctx.cursor[2] or 0
		end
	end
	if not row or not col then
		local cursor = vim.api.nvim_win_get_cursor(0)
		row = cursor[1] - 1
		col = cursor[2]
	end
	line = ctx and ctx.line or vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
	return bufnr, row, col, line:sub(1, col)
end

function M.skill_token_range(ctx)
	local bufnr, row, col, prefix = line_before_cursor(ctx)
	local token_start = prefix:match(".*()%/[%w%-]*$")
	if not token_start then
		return nil
	end
	return bufnr, {
		start = { line = row, character = token_start - 1 },
		["end"] = { line = row, character = col },
	}
end

function M.enabled(bufnr)
	return is_prompt_buffer(bufnr)
end

function M.items(range, callback)
	skill_cache.list(function(skills)
		local items = {}
		for index, skill in ipairs(skills or {}) do
			local name = skill.name
			if type(name) == "string" and name ~= "" then
				table.insert(items, {
					label = "/" .. name,
					kind = vim.lsp.protocol.CompletionItemKind.Reference,
					detail = skill.description or "Pi skill",
					filterText = name .. " /" .. name,
					sortText = string.format("%04d_%s", index, name),
					textEdit = range and {
						newText = "/" .. name,
						range = range,
					} or nil,
					documentation = {
						kind = "markdown",
						value = "`/" .. name .. "`\n\n" .. tostring(skill.description or ""),
					},
				})
			end
		end
		callback(items)
	end)
end

return M
