-- search / :VantageSearch
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq
local lua_buffer = helpers.lua_buffer
local submit_prompt_buffer = helpers.submit_prompt_buffer
local capture_backend_request = helpers.capture_backend_request

test("VantageSearch sends a search request and opens quickfix results", function()
	local vantage = require("vantage")

	local captured = capture_backend_request({
		ok = true,
		result = {
			kind = "locations",
			locations = {
				{
					filePath = "lua/example.lua",
					startLine = 2,
					startCharacter = 4,
					explanation = "Factory creates the target value.",
				},
			},
		},
	}, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({
			"local value = 1",
			"return value",
		})

		vim.cmd("VantageSearch find the factory")
	end)

	eq(captured.method, "searchLocations")
	eq(captured.params.query, "find the factory")
	local qf = vim.fn.getqflist()
	assert(#qf == 1, vim.inspect(qf))
	eq(qf[1].lnum, 2)
	eq(qf[1].col, 4)
	eq(qf[1].text, "Factory creates the target value.")
	vim.cmd("cclose")
end)

test("public search API delegates to VantageSearch behavior", function()
	local vantage = require("vantage")

	local captured = capture_backend_request({
		ok = true,
		result = {
			kind = "locations",
			locations = {},
		},
	}, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({ "local value = 1" })

		vantage.search({ args = "find value" })
	end)

	eq(captured.method, "searchLocations")
	eq(captured.params.query, "find value")
end)

test("ranged VantageSearch requires an explicit prompt", function()
	local vantage = require("vantage")

	local captured = capture_backend_request({
		ok = true,
		result = {
			kind = "locations",
			locations = {},
		},
	}, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({
			"local value = 1",
			"return value",
		})

		vim.cmd("1,2VantageSearch")
		submit_prompt_buffer("find references to value")
	end)

	eq(captured.method, "searchLocations")
	eq(captured.params.query, "find references to value")
	eq(captured.params.range, {
		startLine = 1,
		startCharacter = 1,
		endLine = 2,
		endCharacter = 12,
	})
end)
