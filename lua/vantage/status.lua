local M = {}

local function format_age(ms)
	if type(ms) ~= "number" then
		return "unknown"
	end
	if ms < 1000 then
		return tostring(math.floor(ms)) .. "ms"
	end
	if ms < 60000 then
		return tostring(math.floor((ms / 1000) + 0.5)) .. "s"
	end
	if ms < 3600000 then
		return tostring(math.floor((ms / 60000) + 0.5)) .. "m"
	end
	return tostring(math.floor((ms / 3600000) + 0.5)) .. "h"
end

local function redact_key(key)
	local lowered = tostring(key):lower()
	return lowered:match("key") or lowered:match("token") or lowered:match("secret") or lowered:match("authorization")
end

local function format_value(key, value)
	if redact_key(key) then
		return "<redacted>"
	end
	if type(value) == "table" then
		return vim.inspect(value)
	end
	if value == nil then
		return "nil"
	end
	return tostring(value)
end

local function format_details(details)
	if type(details) ~= "table" then
		return nil
	end

	local parts = {}
	for key, value in pairs(details) do
		if value ~= nil then
			table.insert(parts, tostring(key) .. "=" .. format_value(key, value))
		end
	end
	table.sort(parts)
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, ", ")
end

--- Renders whichever request is currently tracked (explain/question/edit/
--- annotate) -- one tracked request, one status view. `received`/
--- `rendered`/`skipped` are annotate-specific fields that simply won't be
--- present for other commands' status tables.
function M.request(status)
	local lines = {
		"## Vantage Request Status",
		"",
		"- Status: " .. tostring(status.status or "unknown"),
	}
	if status.agent then
		table.insert(lines, "- Agent: " .. tostring(status.agent))
	end
	if status.method then
		table.insert(lines, "- Backend method: " .. tostring(status.method))
	end
	if status.backend_id then
		table.insert(lines, "- Backend request id: `" .. tostring(status.backend_id) .. "`")
	end
	if status.backend_mode then
		table.insert(lines, "- Backend mode: " .. tostring(status.backend_mode))
	end
	if status.timeout_ms then
		table.insert(lines, "- Timeout: " .. tostring(status.timeout_ms) .. "ms")
	end
	if status.elapsed then
		table.insert(lines, "- Elapsed: " .. tostring(status.elapsed))
	end
	if status.scope then
		table.insert(lines, "- Scope: " .. tostring(status.scope))
	end
	if status.selected_line_count then
		table.insert(lines, "- Selected lines: " .. tostring(status.selected_line_count))
	end
	if status.max_annotations then
		table.insert(lines, "- Max annotations: " .. tostring(status.max_annotations))
	end
	if status.candidate_line_count then
		table.insert(lines, "- Candidate lines: " .. tostring(status.candidate_line_count))
	end
	if status.progress_stage then
		table.insert(lines, "- Current backend stage: " .. tostring(status.progress_stage))
	end
	if status.progress_message then
		table.insert(lines, "- Current backend message: " .. tostring(status.progress_message))
	end
	local current_details = format_details(status.progress_details)
	if current_details then
		table.insert(lines, "- Current backend details: " .. current_details)
	end
	if status.received ~= nil then
		table.insert(lines, "- Runtime annotations returned: " .. tostring(status.received))
	end
	if status.rendered ~= nil then
		table.insert(lines, "- Buffer annotations rendered: " .. tostring(status.rendered))
	end
	if status.skipped ~= nil then
		table.insert(lines, "- Returned annotations skipped: " .. tostring(status.skipped))
	end
	if type(status.progress_history) == "table" and #status.progress_history > 0 then
		table.insert(lines, "")
		table.insert(lines, "### Backend Progress")
		table.insert(lines, "")
		for _, event in ipairs(status.progress_history) do
			local detail_text = format_details(event.details)
			local line = "- " .. tostring(event.elapsed or "?") .. " " .. tostring(event.stage or "progress")
			if event.message then
				line = line .. ": " .. tostring(event.message)
			end
			if detail_text then
				line = line .. " (" .. detail_text .. ")"
			end
			table.insert(lines, line)
		end
	end
	if status.error then
		table.insert(lines, "")
		table.insert(lines, "### Error")
		table.insert(lines, "")
		table.insert(lines, tostring(status.error))
	end
	if status.message then
		table.insert(lines, "")
		table.insert(lines, tostring(status.message))
	end
	return table.concat(lines, "\n")
end

local function section(markdown, title)
	local lines = vim.split(markdown or "", "\n", { plain = true })
	if #lines > 0 and lines[1]:match("^##%s+") then
		lines[1] = "### " .. title
	else
		table.insert(lines, 1, "### " .. title)
	end
	for index, line in ipairs(lines) do
		if index > 1 then
			lines[index] = line:gsub("^###%s+", "#### ")
		end
	end
	return table.concat(lines, "\n")
end

function M.agent_context(snapshot)
	local lines = {
		"## Vantage Agent Context Status",
		"",
		"- Enabled: " .. tostring(snapshot.enabled == true),
		"- Status: " .. tostring(snapshot.status or "unknown"),
		"- Workspace root: `" .. tostring(snapshot.workspace_root or "") .. "`",
		"- Path: `" .. tostring(snapshot.path or "") .. "`",
	}

	if snapshot.exists ~= nil then
		table.insert(lines, "- Exists: " .. tostring(snapshot.exists))
	end
	if snapshot.size_bytes ~= nil then
		table.insert(lines, "- File size: " .. tostring(snapshot.size_bytes) .. " bytes")
	end
	if snapshot.included_bytes ~= nil then
		table.insert(lines, "- Included: " .. tostring(snapshot.included_bytes) .. " bytes")
	end
	if snapshot.age_ms ~= nil then
		table.insert(lines, "- Age: " .. format_age(snapshot.age_ms))
	end
	if snapshot.modified_at then
		table.insert(lines, "- Modified: " .. tostring(snapshot.modified_at))
	end
	if snapshot.truncated ~= nil then
		table.insert(lines, "- Tail truncated: " .. tostring(snapshot.truncated))
	end
	if snapshot.error then
		table.insert(lines, "")
		table.insert(lines, "### Error")
		table.insert(lines, "")
		table.insert(lines, tostring(snapshot.error))
	end

	return table.concat(lines, "\n")
end

---Entry counts only -- prompt text never appears in the status float.
---@return string markdown
function M.history()
	local history = require("vantage.history")
	local total = #history.entries()
	local scoped = #history.entries({
		workspace = require("vantage.agent_context").workspace_root() or "",
	})
	return table.concat({
		"## Vantage Prompt History",
		"",
		"Entries: `" .. total .. "` (`" .. scoped .. "` in this workspace)",
	}, "\n")
end

function M.combined(status)
	local lines = {
		"## Vantage Status",
		"",
		section(status.agent_markdown or "## Vantage Agent Session\n\n- Status: unavailable", "Agent Session"),
		"",
		section(M.agent_context(status.agent_context or {}), "Agent Context"),
		"",
		section(M.request(status.request or {}), "Request"),
		"",
		section(M.history(), "History"),
	}
	return table.concat(lines, "\n")
end

return M
