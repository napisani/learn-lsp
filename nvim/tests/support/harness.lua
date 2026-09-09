-- Shared test registry for the Lua suite.
--
-- Spec modules under nvim/tests/spec/ call `test(name, fn)` at require time to
-- register into one global list; nvim/tests/vantage_spec.lua requires them all
-- and then calls `run()`. Keeping the registry here rather than in the
-- aggregator means a spec module never has to know about its siblings.
local M = {}

local tests = {}

---Registers a test. Named `test` so spec files read as plain declarations.
---@param name string
---@param fn fun()
function M.test(name, fn)
	table.insert(tests, { name = name, fn = fn })
end

---How many tests are currently registered.
---@return integer
function M.count()
	return #tests
end

---Runs every registered test, collecting failures so one broken test does not
---hide the rest, then reports them together.
function M.run()
	local failures = {}
	for _, item in ipairs(tests) do
		local ok, err = pcall(item.fn)
		if not ok then
			table.insert(failures, item.name .. ": " .. tostring(err))
		end
	end

	vim.cmd("silent! bufdo setlocal nomodified")

	if #failures > 0 then
		error(table.concat(failures, "\n"))
	end

	print("vantage.nvim tests passed: " .. tostring(#tests))
end

return M
