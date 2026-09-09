-- the .vantage/agent-context.md task snapshot
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq
local fresh_buffer = helpers.fresh_buffer
local lua_buffer = helpers.lua_buffer
local temp_workspace = helpers.temp_workspace
local normalized_path = helpers.normalized_path
local set_buffer_path = helpers.set_buffer_path
local writefile = helpers.writefile
local capture_backend_request = helpers.capture_backend_request

test("agent context reads workspace markdown with tail truncation metadata", function()
	local vantage = require("vantage")
	local agent_context = require("vantage.agent_context")
	local root = temp_workspace()
	local context_path = root .. "/.vantage/agent-context.md"

	vantage.setup({
		backend = { mode = "development" },
		agent_context = {
			max_bytes = 18,
		},
	})

	fresh_buffer()
	set_buffer_path(root .. "/lua/example.lua")
	writefile(context_path, "# Agent Task Context\n\n## Recent Progress\nImplemented reader")

	local snapshot = agent_context.snapshot()

	eq(snapshot.status, "included")
	eq(snapshot.workspace_root, root)
	eq(snapshot.path, context_path)
	eq(snapshot.exists, true)
	eq(snapshot.truncated, true)
	eq(snapshot.included_bytes, 18)
	eq(snapshot.context.path, context_path)
	eq(snapshot.context.truncated, true)
	eq(snapshot.context.content, "Implemented reader")
	assert(type(snapshot.context.revision) == "string", vim.inspect(snapshot.context))
	assert(type(snapshot.context.ageMs) == "number", vim.inspect(snapshot.context))
	assert(type(snapshot.context.modifiedAt) == "string", vim.inspect(snapshot.context))
end)

test("agent context status reports missing context without failing commands", function()
	local vantage = require("vantage")
	local agent_context = require("vantage.agent_context")
	local root = temp_workspace()

	vantage.setup({ backend = { mode = "development" } })
	fresh_buffer()
	vim.fn.mkdir(root .. "/lua", "p")
	set_buffer_path(root .. "/lua/example.lua")

	local snapshot = agent_context.snapshot()

	eq(snapshot.status, "missing")
	eq(snapshot.exists, false)
	eq(snapshot.context, nil)
end)

test("VantageExplain attaches agent context when available", function()
	local vantage = require("vantage")
	local root = temp_workspace()

	vantage.setup({ backend = { mode = "development" } })
	lua_buffer({ "local value = 42" })
	vim.fn.mkdir(root .. "/lua", "p")
	set_buffer_path(root .. "/lua/example.lua")
	writefile(root .. "/.vantage/agent-context.md", "# Agent Task Context\n\n## Goal\nExplain reader")

	local captured = capture_backend_request({
		ok = true,
		result = { kind = "explanation", markdown = "ok" },
	}, function()
		vim.cmd("VantageExplain")
	end)

	eq(captured.method, "explainSelection")
	assert(captured.params.agentContext, vim.inspect(captured.params))
	eq(captured.params.agentContext.content, "# Agent Task Context\n\n## Goal\nExplain reader")
	assert(captured.params.agentContext.revision, vim.inspect(captured.params.agentContext))
	eq(captured.params.agentContext.truncated, false)
	eq(captured.params.workspaceRoot, normalized_path(root))
end)
