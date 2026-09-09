-- the consolidated :VantageStatus float
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq
local close_floating_windows = helpers.close_floating_windows
local fresh_buffer = helpers.fresh_buffer
local lua_buffer = helpers.lua_buffer
local temp_workspace = helpers.temp_workspace
local normalized_path = helpers.normalized_path
local set_buffer_path = helpers.set_buffer_path
local writefile = helpers.writefile
local last_float_text = helpers.last_float_text
local capture_backend_request = helpers.capture_backend_request

test("agent session reset and consolidated status call backend with workspace scope", function()
	local vantage = require("vantage")
	local root = temp_workspace()

	vantage.setup({ backend = { mode = "development" } })
	fresh_buffer()
	vim.fn.mkdir(root .. "/lua", "p")
	writefile(root .. "/lua/example.lua", "local value = 42")
	set_buffer_path(root .. "/lua/example.lua")

	local captured = capture_backend_request({
		ok = true,
		result = { kind = "explanation", markdown = "session reset" },
	}, function()
		vim.cmd("VantageAgentReset")
	end)

	eq(captured.method, "agentSessionReset")
	eq(captured.params.workspaceRoot, normalized_path(root))
	close_floating_windows()

	captured = capture_backend_request({
		ok = true,
		result = { kind = "explanation", markdown = "session status" },
	}, function()
		vim.cmd("VantageStatus")
	end)

	eq(captured.method, "agentSessionStatus")
	eq(captured.params.workspaceRoot, normalized_path(root))
end)

test("VantageStatus shows agent, context, and request sections", function()
	local vantage = require("vantage")
	local root = temp_workspace()

	vantage.setup({ backend = { mode = "development" } })
	fresh_buffer()
	set_buffer_path(root .. "/lua/example.lua")
	writefile(root .. "/.vantage/agent-context.md", "# Agent Task Context\n\n## Goal\nShow status")

	capture_backend_request({
		ok = true,
		result = { kind = "explanation", markdown = "## Vantage Agent Session\n\nSession: `active`" },
	}, function()
		vim.cmd("VantageStatus")
	end)

	local text = last_float_text()
	assert(text ~= nil, "expected consolidated status float")
	assert(text:match("## Vantage Status"), text)
	assert(text:match("### Agent Session"), text)
	assert(text:match("### Agent Context"), text)
	assert(text:match("### Request"), text)
	assert(text:match("Status: included"), text)
	assert(text:match("%.vantage/agent%-context%.md"), text)
end)

test("VantageStatus's request section reflects explain, not just annotate", function()
	local vantage = require("vantage")
	local commands = require("vantage.commands")

	vantage.setup({ backend = { mode = "development" } })
	lua_buffer({ "local value = 42" })
	vantage.explain()

	local status = commands.request_status()
	eq(status.status, "done")
	eq(status.method, "explainSelection")
end)
