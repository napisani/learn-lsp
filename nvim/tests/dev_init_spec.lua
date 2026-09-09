local M = {}

function M.run()
	local state = require("vantage.state")
	local expected_mode = vim.g.vantage_dev_agent == "pi" and "stdio" or "development"
	assert(state.config.backend.mode == expected_mode, "expected dev init to use " .. expected_mode .. " backend")
	assert(
		(state.config.agent or {}).provider == (vim.g.vantage_pi_provider or "openai"),
		"expected agent provider config"
	)
	assert((state.config.agent or {}).model == (vim.g.vantage_pi_model or "gpt-4o-mini"), "expected agent model config")
	if vim.g.vantage_pi_reasoning then
		assert(
			(state.config.agent.options or {}).reasoning == vim.g.vantage_pi_reasoning,
			"expected agent reasoning config"
		)
		assert(
			(state.config.completion.options or {}).reasoning == vim.g.vantage_pi_reasoning,
			"expected completion reasoning config"
		)
	end
	assert(vim.fn.exists(":VantageExplain") == 2, "expected VantageExplain command")

	vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local value = 42" })
	vim.bo.filetype = "lua"

	if expected_mode == "development" then
		vim.cmd("VantageExplain")

		local float_buf = require("vantage.ui").last_float_buf()
		assert(float_buf and vim.api.nvim_buf_is_valid(float_buf), "expected explanation float")
		local text = table.concat(vim.api.nvim_buf_get_lines(float_buf, 0, -1, false), "\n")
		assert(text:match("Development agent runtime"), text)
	end

	vim.cmd("silent! bufdo setlocal nomodified")
end

return M
