local state = require("vantage.state")

local M = {}

local function input_config()
	local ui_config = state.config.ui or {}
	return ui_config.input or {}
end

function M.options(kind, defaults)
	return vim.tbl_deep_extend("force", vim.deepcopy(defaults or {}), input_config()[kind] or {})
end

local function ui2_input(opts, on_confirm)
	local canceled = vim.NIL
	opts = vim.tbl_extend("keep", opts or {}, { cancelreturn = canceled })

	local ok, input = pcall(vim.fn.input, opts)
	if not ok or input == canceled then
		on_confirm(nil)
		return
	end

	on_confirm(input)
end

function M.prompt(kind, defaults, on_confirm)
	local opts = M.options(kind, defaults)
	if input_config().provider == "ui2" then
		ui2_input(opts, on_confirm)
		return
	end

	vim.ui.input(opts, on_confirm)
end

return M
