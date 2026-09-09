local backend_config = require("vantage.backend_config")
local development_backend = require("vantage.development_backend")
local state = require("vantage.state")

local function log_path()
	local debug = state.config and state.config.debug
	return debug and debug.log_path
end

local function write_ndjson(entry)
	local path = log_path()
	if not path then
		return
	end
	local ok, json = pcall(vim.json.encode, entry)
	if not ok then
		return
	end
	local fd, open_err = vim.loop.fs_open(path, "a", 420)
	if not fd then
		return
	end
	vim.loop.fs_write(fd, json .. "\n", 0)
	vim.loop.fs_close(fd)
end

local function log_event(entry)
	entry.ts = os.date("!%Y-%m-%dT%H:%M:%S") .. string.format(".%03dZ", vim.loop.hrtime() % 1000000000 / 1000000)
	write_ndjson(entry)
end

local M = {}

local job_id = nil
local job_generation = 0
local next_id = 1
local pending = {}
local stdout_buffer = ""

local function invoke_callback(callback, response)
	if callback then
		callback(response)
	end
end

local function invoke_progress(callback, progress)
	if callback then
		callback(progress)
	end
end

local function backend_error(id, code, message)
	return {
		id = id,
		ok = false,
		error = {
			code = code,
			message = message,
		},
	}
end

local function fail_pending(code, message)
	local callbacks = pending
	pending = {}
	for id, request in pairs(callbacks) do
		vim.schedule(function()
			invoke_callback(request.callback, backend_error(id, code, message))
		end)
	end
end

local function handle_stdout_line(line)
	if line == "" then
		return
	end

	local ok, decoded = pcall(vim.json.decode, line)
	if not ok or type(decoded) ~= "table" then
		return
	end

	if decoded.type == "progress" then
		local request = pending[decoded.id]
		if request and request.on_progress then
			local progress = decoded.progress or {}
			vim.schedule(function()
				invoke_progress(request.on_progress, progress)
			end)
		end
		return
	end

	local request = pending[decoded.id]
	if request then
		pending[decoded.id] = nil
		vim.schedule(function()
			invoke_callback(request.callback, decoded)
		end)
	end
end

local function handle_stdout(job, data, generation)
	if job_id ~= job or job_generation ~= generation then
		return
	end

	if not data then
		return
	end

	local function flush_line()
		if stdout_buffer ~= "" then
			handle_stdout_line(stdout_buffer)
			stdout_buffer = ""
		end
	end

	local function append_chunk(chunk)
		stdout_buffer = stdout_buffer .. chunk
		while true do
			local newline = stdout_buffer:find("\n", 1, true)
			if not newline then
				break
			end
			local line = stdout_buffer:sub(1, newline - 1)
			stdout_buffer = stdout_buffer:sub(newline + 1)
			handle_stdout_line(line)
		end
	end

	for index, chunk in ipairs(data) do
		if index > 1 then
			flush_line()
		end
		append_chunk(chunk)
	end

	if data[#data] == "" then
		flush_line()
	end
end

local function start_stdio()
	if job_id then
		return nil
	end

	local command = state.config.backend.command
	if not command then
		return "backend.command is required for stdio mode"
	end

	job_generation = job_generation + 1
	local generation = job_generation
	local started = vim.fn.jobstart(command, {
		stdout_buffered = false,
		on_stdout = function(job, data)
			handle_stdout(job, data, generation)
		end,
		on_exit = function(job)
			if job_id ~= job or job_generation ~= generation then
				return
			end

			job_id = nil
			stdout_buffer = ""
			fail_pending("backend_exit", "Vantage backend exited before responding.")
		end,
	})

	if started <= 0 then
		return "failed to start backend command"
	end

	job_id = started
	return nil
end

function M.request(method, params, callback, options)
	if state.config.backend.mode == "development" then
		log_event({ dir = "request", id = "development", method = method })
		local response = {
			id = "development",
			ok = true,
			result = development_backend.response(method, params),
		}
		log_event({ dir = "response", id = "development", ok = true, kind = response.result and response.result.kind })
		invoke_callback(callback, response)
		return "development"
	end

	local start_error = start_stdio()
	if start_error then
		invoke_callback(callback, {
			id = nil,
			ok = false,
			error = start_error,
		})
		return nil
	end

	local id = tostring(next_id)
	next_id = next_id + 1
	local wrapped_callback = callback
	if log_path() then
		local request_method = method
		local original_callback = callback
		wrapped_callback = function(response)
			log_event({
				dir = "response",
				id = id,
				ok = response and response.ok,
				kind = response and response.result and response.result.kind,
				error_code = response and response.error and (response.error.code or tostring(response.error)),
			})
			if original_callback then
				original_callback(response)
			end
		end
	end
	pending[id] = {
		callback = wrapped_callback,
		on_progress = options and options.on_progress or nil,
	}

	log_event({ dir = "request", id = id, method = method })

	local message = vim.json.encode({
		id = id,
		method = method,
		config = backend_config.request(),
		params = params or {},
	}) .. "\n"

	local sent = vim.fn.chansend(job_id, message)
	if sent <= 0 then
		pending[id] = nil
		invoke_callback(callback, backend_error(id, "send_failed", "Failed to send request to Vantage backend."))
		return nil
	end

	return id
end

function M.cancel(id)
	if not id or id == "development" then
		return
	end

	pending[id] = nil
	if not job_id then
		return
	end

	local message = vim.json.encode({
		id = "cancel-" .. tostring(id),
		method = "cancelRequest",
		params = { id = tostring(id) },
	}) .. "\n"

	vim.fn.chansend(job_id, message)
end

function M.stop()
	if job_id then
		vim.fn.jobstop(job_id)
	end

	job_generation = job_generation + 1
	job_id = nil
	pending = {}
	stdout_buffer = ""
end

return M
