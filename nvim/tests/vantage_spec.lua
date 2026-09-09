-- Entry point for the Lua suite: `require("vantage_spec").run()`.
--
-- Tests live in one module per subject under nvim/tests/spec/. Each registers
-- itself into support/harness at require time, so adding a spec module means
-- adding one line to SPECS below -- and adding a test to an existing subject
-- means touching only that subject's file.
--
-- Shared fixtures live in support/helpers.lua. To run a single subject while
-- iterating:
--
--   nvim --headless -u nvim/tests/minimal_init.lua \
--     -c "lua require('spec.explain_spec'); require('support.harness').run()" -c qa
local harness = require("support.harness")

local SPECS = {
	-- plumbing
	"response",
	"backend",
	"state",
	"history",
	"history_store",
	"monitor",
	"monitor_ring",
	"search_replace",
	"monitor_source",
	"context",
	"agent_context",
	"input",
	"commands",

	-- commands
	"explain",
	"question",
	"edit",
	"annotation",
	"annotation_render",
	"annotation_status",
	"search",
	"walkthrough",
	"lens",
	"cancel",

	-- surfaces
	"prompt_buffer",
	"composition",
	"monitor_navigate",
	"monitor_lifecycle",
	"output",
	"session_output",
	"status",
	"health",
}

for _, name in ipairs(SPECS) do
	require("spec." .. name .. "_spec")
end

local M = {}

M.run = harness.run

return M
