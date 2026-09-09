-- :VantageCancel and removed legacy commands
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq
local lua_buffer = helpers.lua_buffer

test("VantageCancel cancels the current tracked request and sends agentCancel", function()
	local vantage = require("vantage")
	local backend = require("vantage.backend")
	local tracker = require("vantage.request_tracker")
	local original_request = backend.request
	local original_cancel = backend.cancel

	local cancelled_backend_id
	local agent_cancel_sent = false

	local ok, err = pcall(function()
		backend.cancel = function(id)
			cancelled_backend_id = id
		end
		backend.request = function(method, _params, callback)
			if method == "agentCancel" then
				agent_cancel_sent = true
				if callback then
					callback({ ok = true, result = { kind = "explanation", markdown = "cancelled" } })
				end
				return "agent-cancel-id"
			end
			-- explainSelection: stays in flight, no callback invoked yet.
			return "explain-backend-id"
		end

		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({ "local value = 42" })
		vantage.explain()
		eq(tracker.status().status, "loading")

		vim.cmd("VantageCancel")
	end)

	backend.request = original_request
	backend.cancel = original_cancel
	assert(ok, err)

	eq(cancelled_backend_id, "explain-backend-id")
	assert(agent_cancel_sent, "expected VantageCancel to also send agentCancel")
	eq(tracker.status().status, "cancelled")
end)

test("VantageComplete and VantageAgentCancel no longer exist", function()
	local vantage = require("vantage")
	vantage.setup({ backend = { mode = "development" } })

	local ok_complete = pcall(vim.cmd, "VantageComplete")
	local ok_agent_cancel = pcall(vim.cmd, "VantageAgentCancel")

	assert(not ok_complete, "expected VantageComplete to no longer be a registered command")
	assert(not ok_agent_cancel, "expected VantageAgentCancel to no longer be a registered command")
end)
