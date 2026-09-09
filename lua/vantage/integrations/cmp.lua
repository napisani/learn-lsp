local M = {}

function M.setup(opts)
	opts = opts or {}
	local ok, cmp = pcall(require, "cmp")
	if not ok then
		return false, "nvim-cmp is not available"
	end

	local skills = require("vantage.completion.skills")
	local source = {}

	function source:is_available()
		return skills.enabled(vim.api.nvim_get_current_buf())
	end

	function source:get_trigger_characters()
		return { "/" }
	end

	function source:complete(params, callback)
		local ctx = {
			bufnr = params.context and params.context.bufnr or vim.api.nvim_get_current_buf(),
			cursor = params.context and params.context.cursor,
			line = params.context and params.context.cursor_before_line,
		}
		local _, range = skills.skill_token_range(ctx)
		if not range then
			callback({ items = {}, isIncomplete = false })
			return
		end
		skills.items(range, function(items)
			callback({ items = items, isIncomplete = false })
		end)
	end

	cmp.register_source(opts.name or "vantage_skills", source)
	return true
end

return M
