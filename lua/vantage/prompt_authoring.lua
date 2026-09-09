local prompt_buffer = require("vantage.ui.prompt_buffer")

local M = {}

local function trim(text)
	return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.command_text(opts)
	local text = trim(opts and opts.args or "")
	if text:match("%S") == nil then
		return nil
	end
	return text
end

function M.resolve(opts)
	opts = opts or {}
	local text = M.command_text(opts.command_opts)
	if text then
		-- Inline args bypass the prompt buffer entirely, so this is the only place
		-- that path can be recorded. Excluding it would make history mysteriously
		-- miss the prompts typed fastest.
		pcall(require("vantage.history").record, {
			kind = opts.kind,
			text = text,
			submitted = true,
			workspaceRoot = (opts.params or {}).workspaceRoot,
			filePath = (opts.params or {}).filePath,
		})
		opts.on_submit(text, opts.runtime)
		return true
	end

	prompt_buffer.open({
		kind = opts.kind or "prompt",
		params = opts.params or {},
		runtime = opts.runtime,
		show_runtime_toggle = opts.show_runtime_toggle,
		on_submit = function(input, runtime)
			local submitted = M.command_text({ args = input })
			if not submitted then
				if opts.empty_message then
					vim.notify(opts.empty_message, vim.log.levels.WARN)
				end
				return
			end
			opts.on_submit(submitted, runtime)
		end,
	})
	return false
end

return M
