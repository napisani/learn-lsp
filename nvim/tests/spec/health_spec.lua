-- vantage.health checks and :VantageHealth
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq
local close_floating_windows = helpers.close_floating_windows

test("vantage.health.check reports backend, model, auth, and agent context sections", function()
	local vantage = require("vantage")
	vantage.setup({ backend = { mode = "development" } })

	local sections = {}
	local reports = {}
	local original_health = vim.health
	local ok, err = pcall(function()
		vim.health = {
			start = function(name)
				table.insert(sections, name)
			end,
			ok = function(msg)
				table.insert(reports, { level = "ok", msg = msg })
			end,
			warn = function(msg)
				table.insert(reports, { level = "warn", msg = msg })
			end,
			error = function(msg)
				table.insert(reports, { level = "error", msg = msg })
			end,
			info = function(msg)
				table.insert(reports, { level = "info", msg = msg })
			end,
		}
		require("vantage.health").check()
	end)
	vim.health = original_health
	assert(ok, err)

	eq(sections, { "vantage.nvim", "Backend", "Model target", "Pi auth", "Agent Context File" })

	local backend_ok = false
	local model_ok = false
	for _, report in ipairs(reports) do
		if report.level == "ok" and report.msg:match("^Backend mode: development") then
			backend_ok = true
		end
		if report.level == "ok" and report.msg:match("^Model target resolves: openai/gpt%-4o%-mini") then
			model_ok = true
		end
		assert(report.level ~= "error", report.msg)
	end
	assert(backend_ok, vim.inspect(reports))
	assert(model_ok, vim.inspect(reports))
end)

test("VantageHealth opens :checkhealth vantage", function()
	local vantage = require("vantage")
	vantage.setup({ backend = { mode = "development" } })

	close_floating_windows()
	vim.cmd("silent! %bwipeout!")
	vim.cmd("VantageHealth")

	local found = false
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_get_option(buf, "filetype") == "checkhealth" then
			found = true
		end
	end
	assert(found, "expected a checkhealth buffer to open")
end)
