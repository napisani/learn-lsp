-- vantage.state configuration and lens storage
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq

test("adjacent runtime and explicit socket survive backend configuration serialization", function()
	local vantage = require("vantage")
	vantage.setup({
		backend = { mode = "development" },
		agent = { runtime = "adjacent", adjacent = { socket_path = "/tmp/private/pi.sock" } },
	})
	local config = require("vantage.backend_config").request()
	eq(config.agent.runtime, "adjacent")
	eq(config.agent.adjacent.socket_path, "/tmp/private/pi.sock")
	local decoded = vim.json.decode(vim.json.encode(config))
	eq(decoded.agent.adjacent.socket_path, "/tmp/private/pi.sock")
	vantage.setup({ backend = { mode = "development" } })
end)

test("adjacent-or-pi runtime survives backend configuration serialization", function()
	local vantage = require("vantage")
	vantage.setup({ backend = { mode = "development" }, agent = { runtime = "adjacent-or-pi" } })
	local config = require("vantage.backend_config").request()
	eq(vim.json.decode(vim.json.encode(config)).agent.runtime, "adjacent-or-pi")
	vantage.setup({ backend = { mode = "development" } })
end)

test("state stores and clears a lens", function()
	local vantage = require("vantage")
	vantage.setup({ backend = { mode = "development" } })
	vantage.set_lens("learning", "I am learning Lua syntax")
	eq(vantage.get_lens(), { mode = "learning", text = "I am learning Lua syntax" })
	vantage.clear_lens()
	eq(vantage.get_lens(), nil)
end)
