local state = require("vantage.state")
local agent_context = require("vantage.agent_context")

local M = {}

local function check_backend()
	local backend_cfg = state.config.backend or {}

	if backend_cfg.mode == "development" then
		vim.health.ok("Backend mode: development (no external process required)")
		return
	end

	if vim.fn.executable("node") == 1 then
		vim.health.ok("node executable found on PATH")
	else
		vim.health.error("node executable not found on PATH", "Install Node.js 22+ (required to run the Vantage backend).")
	end

	local command = backend_cfg.command
	if type(command) ~= "table" or #command == 0 then
		vim.health.error("backend.command is not configured")
		return
	end

	local server_path = command[#command]
	if type(server_path) == "string" and vim.loop.fs_stat(server_path) then
		vim.health.ok("Backend server script found: " .. server_path)
	else
		vim.health.error(
			"Backend server script not found: " .. tostring(server_path),
			"Run `npm ci --omit=dev && npm run compile` in the plugin directory."
		)
	end
end

local function check_model()
	local model = state.current_model or state.resolve_model()
	if model then
		vim.health.ok("Model target resolves: " .. model.provider .. "/" .. model.model)
	else
		vim.health.error("No model target configured", "Add at least one entry to agent.models in setup().")
	end
end

-- Mirrors PiOAuthCredentialResolver's own default candidate order
-- (server/src/neovim/pi-oauth-auth.ts) minus the cwd/workspaceRoot
-- candidates, which are session-relative rather than a fixed "default
-- location" this health check can meaningfully report on.
local function default_auth_paths()
	return {
		vim.fn.expand("~/.pi/agent/auth.json"),
		vim.fn.expand("~/.config/pi/auth.json"),
		vim.fn.expand("~/.config/pi-ai/auth.json"),
	}
end

local function check_auth()
	local auth_cfg = (state.config.agent and state.config.agent.auth) or {}
	local configured_path = auth_cfg.path

	if configured_path then
		if vim.loop.fs_stat(configured_path) then
			vim.health.ok("Pi OAuth auth file found: " .. configured_path)
		else
			vim.health.warn(
				"Configured agent.auth.path not found: " .. configured_path,
				"Run `npx @earendil-works/pi-ai login <provider>`, or confirm the provider uses an API key instead."
			)
		end
		return
	end

	local default_paths = default_auth_paths()
	for _, path in ipairs(default_paths) do
		if vim.loop.fs_stat(path) then
			vim.health.ok("Pi OAuth auth file found at default location: " .. path)
			return
		end
	end

	vim.health.info(
		"No Pi OAuth auth file found at "
			.. table.concat(default_paths, ", ")
			.. " — fine if your configured provider(s) use API keys instead."
	)
end

local function check_agent_context()
	local snapshot = agent_context.snapshot()

	if not snapshot.enabled then
		vim.health.info("Agent Context File integration disabled (agent_context.enabled = false)")
		return
	end

	if snapshot.status == "missing" then
		vim.health.info(
			"Agent Context File not found at " .. snapshot.path .. " (fine if you haven't run an adjacent coding agent yet)"
		)
		return
	end

	if snapshot.status == "unavailable" then
		vim.health.warn("Agent Context File unavailable: " .. tostring(snapshot.error))
		return
	end

	vim.health.ok(
		"Agent Context File found: "
			.. snapshot.path
			.. " ("
			.. tostring(snapshot.size_bytes)
			.. " bytes, modified "
			.. tostring(snapshot.modified_at)
			.. ")"
	)
end

function M.check()
	vim.health.start("vantage.nvim")

	vim.health.start("Backend")
	check_backend()

	vim.health.start("Model target")
	check_model()

	vim.health.start("Pi auth")
	check_auth()

	vim.health.start("Agent Context File")
	check_agent_context()
end

return M
