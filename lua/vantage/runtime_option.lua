-- Parses a `runtime=agent`/`runtime=completion` token out of a command's
-- args, shared by explain/question/annotate (the commands that accept a
-- runtime override). The token can appear anywhere among the command's
-- fargs; everything else is left untouched and rejoined for callers (like
-- question/edit/search) that treat the remaining text as freeform prompt
-- content via opts.args.
local M = {}

local VALID_RUNTIMES = { agent = true, completion = true }

--- Extracts a `runtime=` token from `opts.fargs`/`opts.args`, returning the
--- runtime value (or nil if none given) and a new opts-shaped table with
--- that token removed from both fargs and args. Does not mutate `opts`.
---@param opts table? a nvim_create_user_command callback's opts (fargs/args/...)
---@return "agent"|"completion"|nil runtime
---@return table remaining_opts opts with the runtime token stripped
---@return string|nil error message if a runtime= token had an invalid value
function M.extract(opts)
	opts = opts or {}
	local fargs = opts.fargs or {}
	local runtime = nil
	local remaining_fargs = {}

	for _, arg in ipairs(fargs) do
		local value = arg:match("^runtime=(.+)$")
		if value then
			if not VALID_RUNTIMES[value] then
				return nil, opts, 'invalid runtime "' .. value .. '" (expected "agent" or "completion")'
			end
			runtime = value
		else
			table.insert(remaining_fargs, arg)
		end
	end

	local remaining_opts = vim.tbl_extend("force", {}, opts, {
		fargs = remaining_fargs,
		args = table.concat(remaining_fargs, " "),
	})
	return runtime, remaining_opts, nil
end

return M
