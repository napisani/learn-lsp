-- annotation request lifecycle: progress, waiting, cancel, timeout, status
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq
local lua_buffer = helpers.lua_buffer
local capture_notifications = helpers.capture_notifications
local capture_backend_request = helpers.capture_backend_request

test("annotate reports request progress", function()
	local vantage = require("vantage")
	local commands = require("vantage.commands")
	local annotations = require("vantage.annotations")

	local notifications = capture_notifications(function()
		vantage.setup({ backend = { mode = "development" } })
		annotations.clear(0)
		lua_buffer({ "local value = 42" })

		commands.annotate()
	end)

	assert(notifications[1] and notifications[1]:match("requesting annotations"), vim.inspect(notifications))
	assert(notifications[#notifications] and notifications[#notifications]:match("rendered 1 annotation"), vim.inspect(notifications))
	local status = commands.request_status()
	eq(status.status, "rendered")
	eq(status.received, 1)
	eq(status.rendered, 1)
end)

test("annotation status reports returned annotations that did not render", function()
	local vantage = require("vantage")
	local commands = require("vantage.commands")
	local annotations = require("vantage.annotations")

	vantage.setup({ backend = { mode = "development" } })
	annotations.clear(0)
	lua_buffer({ "local value = 42" })

	capture_backend_request({
		ok = true,
		result = {
			kind = "annotations",
			annotations = {
				{
					text = "Out of range annotation",
					severity = "info",
					range = {
						startLine = 100,
						startCharacter = 1,
						endLine = 100,
						endCharacter = 0,
					},
				},
			},
		},
	}, function()
		commands.annotate()
	end)

	local status = commands.request_status()
	eq(status.status, "no_visible_annotations")
	eq(status.received, 1)
	eq(status.rendered, 0)
	eq(status.skipped, 1)
	assert(status.message:match("not visible"), status.message)
end)

test("annotation status includes request details and backend progress", function()
	local vantage = require("vantage")
	local commands = require("vantage.commands")
	local annotations = require("vantage.annotations")
	local backend = require("vantage.backend")
	local original_request = backend.request

	local ok, err = pcall(function()
		backend.request = function(_method, _params, _callback, options)
			if options and options.on_progress then
				options.on_progress({
					stage = "credentials_check",
					message = "Checking Pi OAuth credentials.",
					details = {
						provider = "openai-codex",
						auth_path = "~/.config/pi/auth.json",
					},
				})
			end
			return "progress-annotations"
		end

		vantage.setup({
			backend = { mode = "stdio" },
			agent = {
				models = {
					{
						name = "codex",
						provider = "openai-codex",
						model = "gpt-5.3-codex",
					},
				},
				default_model = "codex",
			},
			commands = {
				annotate = {
					options = {
						timeoutMs = 300000,
					},
				},
			},
		})
		annotations.clear(0)
		lua_buffer({ "local value = 42" })

		commands.annotate()

		local status = commands.request_status()
		eq(status.status, "loading")
		eq(status.agent, "openai-codex/gpt-5.3-codex")
		eq(status.backend_id, "progress-annotations")
		eq(status.timeout_ms, 300000)
		eq(status.selected_line_count, 1)
		eq(status.max_annotations, 1)
		eq(status.progress_stage, "credentials_check")
		assert(status.progress_message:match("OAuth"), vim.inspect(status))
		assert(#status.progress_history == 1, vim.inspect(status.progress_history))

		commands.clear_annotations()
	end)

	backend.request = original_request
	assert(ok, err)
end)

test("annotate cancels an in-flight annotation request and ignores its late response", function()
	local vantage = require("vantage")
	local commands = require("vantage.commands")
	local annotations = require("vantage.annotations")
	local backend = require("vantage.backend")
	local original_request = backend.request
	local original_cancel = backend.cancel
	local callbacks = {}
	local request_count = 0
	local cancelled_id

	local ok, err = pcall(function()
		backend.request = function(_method, _params, callback)
			request_count = request_count + 1
			callbacks[request_count] = callback
			return "slow-annotations-" .. tostring(request_count)
		end
		backend.cancel = function(id)
			cancelled_id = id
		end

		vantage.setup({ backend = { mode = "development" } })
		annotations.clear(0)
		lua_buffer({ "local value = 42" })

		local notifications = capture_notifications(function()
			commands.annotate()
			commands.annotate()
		end)

		assert(request_count == 2, "expected second annotate to cancel and start a new request")
		assert(cancelled_id == "slow-annotations-1", "expected cancellation to propagate to backend")
		local saw_cancel = false
		for _, notification in ipairs(notifications) do
			saw_cancel = saw_cancel or notification:match("cancelled annotation request") ~= nil
		end
		assert(saw_cancel, vim.inspect(notifications))

		callbacks[1]({
			ok = true,
			result = {
				kind = "annotations",
				annotations = {
					{
						text = "Late annotation",
						severity = "info",
						range = {
							startLine = 1,
							startCharacter = 1,
							endLine = 1,
							endCharacter = 0,
						},
					},
				},
			},
		})

		assert(#annotations.current_marks(0) == 0, "expected cancelled response to be ignored")

		callbacks[2]({
			ok = true,
			result = {
				kind = "annotations",
				annotations = {
					{
						text = "Current annotation",
						severity = "info",
						range = {
							startLine = 1,
							startCharacter = 1,
							endLine = 1,
							endCharacter = 0,
						},
					},
				},
			},
		})
		assert(#annotations.current_marks(0) == 1, "expected second response to render")
	end)

	backend.request = original_request
	backend.cancel = original_cancel
	annotations.clear(0)
	assert(ok, err)
end)

test("annotate times out when the backend leaves the request pending", function()
	local vantage = require("vantage")
	local commands = require("vantage.commands")
	local backend = require("vantage.backend")
	local original_request = backend.request
	local original_cancel = backend.cancel
	local cancelled_id

	local ok, err = pcall(function()
		backend.request = function()
			return "orphaned-annotations"
		end
		backend.cancel = function(id)
			cancelled_id = id
		end

		vantage.setup({
			backend = { mode = "stdio" },
			commands = {
				annotate = {
					options = {
						timeoutMs = 20,
					},
				},
			},
		})
		lua_buffer({ "local value = 42" })

		commands.annotate()
		vim.wait(500, function()
			return commands.request_status().status == "failed"
		end)

		local status = commands.request_status()
		eq(status.status, "failed")
		assert(status.error:match("timed out"), vim.inspect(status))
		assert(cancelled_id == "orphaned-annotations", "expected timeout to cancel backend request")
	end)

	backend.request = original_request
	backend.cancel = original_cancel
	assert(ok, err)
end)

test("annotate waiting status includes agent and elapsed time", function()
	local vantage = require("vantage")
	local commands = require("vantage.commands")
	local backend = require("vantage.backend")
	local original_request = backend.request

	local ok, err = pcall(function()
		backend.request = function()
			-- Keep the request in-flight so the waiting status can fire.
		end

		vantage.setup({
			backend = { mode = "development" },
			commands = {
				annotate = {
					waiting_message_ms = 10,
				},
			},
		})
		lua_buffer({ "local value = 42" })

		capture_notifications(function(notifications)
			commands.annotate()
			local saw_waiting_status = vim.wait(200, function()
				for _, notification in ipairs(notifications) do
					if notification:match("still waiting for annotations from development") and notification:match("after 0%.") then
						return true
					end
				end
				return false
			end)
			assert(saw_waiting_status, vim.inspect(notifications))
			commands.clear_annotations()
		end)
	end)

	backend.request = original_request
	vantage.setup({ commands = { annotate = { waiting_message_ms = 30000 } } })
	assert(ok, err)
end)

test("annotation status uses configured model target", function()
	local vantage = require("vantage")
	local commands = require("vantage.commands")
	local backend = require("vantage.backend")
	local original_request = backend.request

	local ok, err = pcall(function()
		backend.request = function()
			-- Keep the request in-flight so only the start status matters.
		end

		vantage.setup({
			backend = { mode = "stdio" },
			agent = {
				models = {
					{
						name = "test",
						provider = "anthropic",
						model = "claude-sonnet-4",
					},
				},
				default_model = "test",
			},
			commands = {
				annotate = {
					waiting_message_ms = 30000,
				},
			},
		})
		lua_buffer({ "local value = 42" })

		local notifications = capture_notifications(function()
			commands.annotate()
			commands.clear_annotations()
		end)

		assert(
			notifications[1] == "Vantage: requesting annotations from anthropic/claude-sonnet-4",
			vim.inspect(notifications)
		)
	end)

	backend.request = original_request
	vantage.setup({ commands = { annotate = { waiting_message_ms = 30000 } } })
	assert(ok, err)
end)
