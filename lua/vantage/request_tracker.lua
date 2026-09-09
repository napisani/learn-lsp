local backend = require("vantage.backend")

-- Tracks the single "current" Vantage request across explain/question/edit/
-- annotate, generalized from annotation_command.lua's original per-command
-- annotation_request table. There is exactly one current request at a time:
-- starting a new one (begin) supersedes whatever was previously tracked via
-- the token bump, matching a single-editor, one-thing-at-a-time model.
local M = {}

local current = {
	status = "idle",
	token = 0,
	started_at = 0,
	agent = nil,
	backend_id = nil,
	label = "request",
	details = {},
	progress_history = {},
	progress_stage = nil,
	progress_message = nil,
	progress_details = nil,
}

local last_status = {
	status = "idle",
	message = "No request has completed yet.",
}

local function copy_table(value)
	if type(value) ~= "table" then
		return nil
	end
	return vim.deepcopy(value)
end

local function agent_label(agent)
	return agent and agent.label or "unknown"
end

local function elapsed_seconds()
	if not current.started_at or current.started_at == 0 then
		return 0
	end
	return math.max(0, (vim.loop.hrtime() - current.started_at) / 1000000000)
end

local function format_elapsed(seconds)
	if seconds < 10 then
		return string.format("%.1fs", seconds)
	end
	return tostring(math.floor(seconds + 0.5)) .. "s"
end

local function progress_fields()
	local fields = {}
	if current.progress_stage then
		fields.progress_stage = current.progress_stage
	end
	if current.progress_message then
		fields.progress_message = current.progress_message
	end
	if current.progress_details then
		fields.progress_details = copy_table(current.progress_details)
	end
	if current.progress_history and #current.progress_history > 0 then
		fields.progress_history = copy_table(current.progress_history)
	end
	return fields
end

local function status_details()
	return vim.tbl_deep_extend("force", {}, current.details or {}, progress_fields(), {
		backend_id = current.backend_id,
	})
end

local function set_status(status)
	last_status = vim.tbl_deep_extend("force", {}, status or {})
	last_status.updated_at = vim.loop.hrtime()
end

--- Starts tracking a new request, superseding whatever was previously
--- tracked. Callers are responsible for cancelling a prior in-flight request
--- themselves first if that's the desired behavior (annotate already does
--- this today via M.cancel before calling M.begin again).
---@param agent { name: string, label: string }
---@param details table? extra fields surfaced via M.status(), e.g. method/scope
---@param opts { label: string?, waiting_message_ms: number?, silent: boolean? }?
---@return integer token
function M.begin(agent, details, opts)
	opts = opts or {}
	current.status = "loading"
	current.token = current.token + 1
	current.started_at = vim.loop.hrtime()
	current.agent = agent
	current.backend_id = nil
	current.label = opts.label or "request"
	current.details = details or {}
	current.progress_history = {}
	current.progress_stage = nil
	current.progress_message = nil
	current.progress_details = nil
	local token = current.token

	set_status(vim.tbl_deep_extend("force", status_details(), {
		status = "loading",
		agent = agent_label(agent),
		message = "Vantage " .. current.label .. " is still waiting for " .. agent_label(agent) .. ".",
	}))
	-- Status is always tracked (so :VantageStatus reflects reality even for
	-- silent/programmatic calls); `silent` only suppresses user-facing
	-- notifications, matching how callback-driven callers (e.g. explain with
	-- an opts.callback) already skip their own requesting/done notifications.
	if not opts.silent then
		vim.notify("Vantage: requesting " .. current.label .. " from " .. agent.label, vim.log.levels.INFO)
	end

	local waiting_message_ms = opts.waiting_message_ms
	if type(waiting_message_ms) == "number" and waiting_message_ms >= 0 then
		vim.defer_fn(function()
			if current.status == "loading" and current.token == token then
				local elapsed = format_elapsed(elapsed_seconds())
				set_status(vim.tbl_deep_extend("force", status_details(), {
					status = "loading",
					agent = agent_label(agent),
					elapsed = elapsed,
					message = "Vantage " .. current.label .. " is still waiting after " .. elapsed .. ".",
				}))
				if not opts.silent then
					vim.notify(
						"Vantage: still waiting for " .. current.label .. " from " .. agent.label .. " after " .. elapsed,
						vim.log.levels.WARN
					)
				end
			end
		end, waiting_message_ms)
	end

	return token
end

--- Schedules a timeout that cancels the backend request and marks the
--- tracked request failed if it's still the current one and still loading
--- when the timer fires. `on_timeout(status)`, if given, is called with the
--- resulting status table — e.g. to show it as markdown — so the tracker
--- itself stays free of UI concerns.
---@param token integer
---@param timeout_ms number
---@param on_timeout (fun(status: table))?
function M.schedule_timeout(token, timeout_ms, on_timeout)
	vim.defer_fn(function()
		if current.status ~= "loading" or current.token ~= token then
			return
		end

		local agent = current.agent
		local backend_id = current.backend_id
		if backend_id then
			backend.cancel(backend_id)
		end

		local elapsed = M.complete(token)
		if not elapsed then
			return
		end

		local error_message = "Vantage " .. current.label .. " timed out after " .. elapsed .. " without a backend response."
		local status = vim.tbl_deep_extend("force", status_details(), {
			status = "failed",
			agent = agent_label(agent),
			elapsed = elapsed,
			error = error_message,
			message = error_message,
		})
		set_status(status)
		vim.notify(
			"Vantage: " .. current.label .. " from " .. agent_label(agent) .. " timed out after " .. elapsed,
			vim.log.levels.ERROR
		)
		if on_timeout then
			on_timeout(status)
		end
	end, timeout_ms)
end

--- Late-bind the backend request id once backend.request() returns one, so
--- M.cancel() can call backend.cancel(id). No-op if `token` is no longer the
--- current request (it completed or was superseded before the id came back).
function M.set_backend_id(token, id)
	if current.token == token and current.status == "loading" then
		current.backend_id = id
	end
end

--- Records a progress event for `token`, updating the tracked status. No-op
--- if `token` is no longer the current request.
function M.push_progress(token, progress)
	if current.status ~= "loading" or current.token ~= token then
		return
	end

	progress = progress or {}
	local event = {
		stage = progress.stage or "progress",
		message = progress.message,
		details = progress.details,
		elapsed = format_elapsed(elapsed_seconds()),
	}
	table.insert(current.progress_history, event)
	while #current.progress_history > 8 do
		table.remove(current.progress_history, 1)
	end

	current.progress_stage = event.stage
	current.progress_message = event.message
	current.progress_details = event.details
	set_status(vim.tbl_deep_extend("force", status_details(), {
		status = "loading",
		agent = agent_label(current.agent),
		elapsed = event.elapsed,
		message = event.message or ("Vantage " .. current.label .. " reached " .. event.stage .. "."),
	}))
end

--- Marks `token`'s request done, if it's still the current, still-loading
--- request. Returns the formatted elapsed time, or nil if `token` was
--- already superseded/completed (callers should treat nil as "ignore this
--- callback" — matches annotate's existing complete_annotation_request).
---@return string|nil elapsed
function M.complete(token)
	if current.token ~= token or current.status ~= "loading" then
		return nil
	end

	local elapsed = format_elapsed(elapsed_seconds())
	current.status = "idle"
	current.backend_id = nil
	return elapsed
end

--- Cancels the current request if one is loading: aborts it via
--- backend.cancel(id) and marks it cancelled. No-op (returns false) if
--- nothing is currently tracked as loading.
---@param message_prefix string? if given, vim.notify's the cancellation
---@return boolean cancelled
function M.cancel(message_prefix)
	if current.status ~= "loading" then
		return false
	end

	local agent = current.agent
	local elapsed = format_elapsed(elapsed_seconds())
	backend.cancel(current.backend_id)
	current.status = "idle"
	current.token = current.token + 1
	current.backend_id = nil
	set_status(vim.tbl_deep_extend("force", status_details(), {
		status = "cancelled",
		agent = agent_label(agent),
		elapsed = elapsed,
		message = "Vantage " .. current.label .. " cancelled after " .. elapsed .. ".",
	}))
	if message_prefix then
		vim.notify(message_prefix .. " " .. agent_label(agent) .. " after " .. elapsed, vim.log.levels.INFO)
	end
	return true
end

--- Sets the tracked request's terminal status (failed/rendered/whatever the
--- caller's domain-specific outcome is) after M.complete() returns a
--- non-nil elapsed. Merges over the current details/progress fields so
--- domain-specific fields set via M.begin()'s `details` stay visible.
function M.set_result_status(status)
	set_status(vim.tbl_deep_extend("force", status_details(), status or {}))
end

--- Current tracked request's status, for :VantageStatus. Reflects whatever
--- is currently loading, or the last completed/cancelled/failed request.
function M.status()
	local status = vim.deepcopy(last_status)
	if current.status == "loading" then
		local elapsed = format_elapsed(elapsed_seconds())
		status = vim.tbl_deep_extend("force", status, status_details(), {
			status = "loading",
			agent = agent_label(current.agent),
			elapsed = elapsed,
			message = current.progress_message or ("Vantage " .. current.label .. " is still waiting after " .. elapsed .. "."),
		})
	end
	return status
end

return M
