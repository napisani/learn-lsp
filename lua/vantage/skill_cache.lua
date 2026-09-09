local backend = require("vantage.backend")
local context = require("vantage.context")
local response_util = require("vantage.response")

local M = {}

local cached = nil
local loading = false
local waiters = {}

local function complete(skills)
	cached = skills or {}
	loading = false
	local callbacks = waiters
	waiters = {}
	for _, callback in ipairs(callbacks) do
		callback(cached)
	end
end

function M.list(callback)
	if cached then
		callback(cached)
		return
	end
	table.insert(waiters, callback)
	if loading then
		return
	end
	loading = true
	backend.request("listSkills", context.current_line(), function(response)
		local result = response_util.unwrap(response, "skills")
		complete(result and result.skills or {})
	end)
end

function M.cached()
	return cached or {}
end

function M.clear()
	cached = nil
	loading = false
	waiters = {}
end

return M
