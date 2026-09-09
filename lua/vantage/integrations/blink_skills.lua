local skills = require("vantage.completion.skills")

local source = {}

function source.new(opts)
	local self = setmetatable({}, { __index = source })
	self.opts = opts or {}
	return self
end

function source:enabled()
	return skills.enabled(vim.api.nvim_get_current_buf())
end

function source:get_trigger_characters()
	return { "/" }
end

function source:get_completions(ctx, callback)
	local bufnr, range = skills.skill_token_range(ctx)
	if not range or not skills.enabled(bufnr) then
		callback({ items = {}, is_incomplete_backward = false, is_incomplete_forward = false })
		return
	end
	skills.items(range, function(items)
		callback({
			items = items,
			is_incomplete_backward = false,
			is_incomplete_forward = false,
		})
	end)
end

return source
