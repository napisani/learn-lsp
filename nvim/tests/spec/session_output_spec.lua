-- :VantageSessionOutput
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq
local prompt_buffer_footer_text = helpers.prompt_buffer_footer_text
local capture_backend_request = helpers.capture_backend_request

test("VantageSessionOutput shows an unchecked raw/close keybind footer", function()
	local vantage = require("vantage")
	local ui = require("vantage.ui")

	vantage.setup({ backend = { mode = "development" } })

	capture_backend_request({
		ok = true,
		result = { kind = "explanation", markdown = "session transcript" },
	}, function()
		vim.cmd("VantageSessionOutput")
	end)

	eq(prompt_buffer_footer_text(), " [ ] raw r  close q ")
	vim.api.nvim_win_close(ui.last_float_win(), true)
end)
