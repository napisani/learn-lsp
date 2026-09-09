local annotations = require("vantage.annotations")
local backend = require("vantage.backend")
local context = require("vantage.context")
local response_util = require("vantage.response")
local state = require("vantage.state")
local tracker = require("vantage.request_tracker")
local ui = require("vantage.ui")
local walkthrough = require("vantage.walkthrough")

local M = {}

local LINE_ANNOTATION_LIMIT = 1
local SCOPE_ANNOTATION_PERCENT = 0.25
local SCOPE_ANNOTATION_MIN = 1
local SCOPE_ANNOTATION_MAX = 12
local BUFFER_ANNOTATION_PERCENT = 0.15
local BUFFER_ANNOTATION_MIN = 3
local BUFFER_ANNOTATION_MAX = 24

local function annotation_count(value)
	if type(value) == "table" then
		return #value
	end
	return 0
end

local function annotation_agent()
	local backend_config = state.config.backend or {}
	local mode = backend_config.mode or "stdio"
	if mode == "development" then
		return {
			name = "development",
			label = "development",
		}
	end

	local agent_config = state.config.agent or {}
	local provider = agent_config.provider or "openai"
	local model = agent_config.model or "gpt-4o-mini"
	local label = provider .. "/" .. model

	return {
		name = "pi",
		label = label,
	}
end

local function waiting_message_ms()
	local commands = state.config.commands or {}
	local config = commands.annotate or {}
	local value = config.waiting_message_ms
	if type(value) == "number" and value >= 0 then
		return value
	end
	return 30000
end

local function annotation_request_timeout_ms()
	local commands = state.config.commands or {}
	local annotate = commands.annotate or {}
	local options = annotate.options or {}
	local value = options.timeoutMs
	if type(value) == "number" and value > 0 then
		return value
	end
	return 300000
end

local function format_elapsed(seconds)
	if seconds < 10 then
		return string.format("%.1fs", seconds)
	end
	return tostring(math.floor(seconds + 0.5)) .. "s"
end

local function telemetry_suffix(result)
	local telemetry = result and result.telemetry
	if type(telemetry) ~= "table" then
		return ""
	end

	local details = {}
	if type(telemetry.totalDurationMs) == "number" then
		table.insert(details, "runtime " .. format_elapsed(telemetry.totalDurationMs / 1000))
	end
	if type(telemetry.promptEvalCount) == "number" then
		table.insert(details, "prompt tokens " .. tostring(telemetry.promptEvalCount))
	end
	if type(telemetry.evalCount) == "number" then
		table.insert(details, "output tokens " .. tostring(telemetry.evalCount))
	end
	if type(telemetry.promptChars) == "number" then
		table.insert(details, "prompt chars " .. tostring(telemetry.promptChars))
	end

	if #details == 0 then
		return ""
	end
	return " (" .. table.concat(details, ", ") .. ")"
end

local function no_annotations_markdown()
	return table.concat({
		"## No annotations",
		"",
		"The agent runtime did not return visible annotations for this window.",
	}, "\n")
end

local function split_lines(text)
	if text == "" then
		return { "" }
	end

	local lines = {}
	for line in (text .. "\n"):gmatch("(.-)\n") do
		table.insert(lines, line)
	end
	return lines
end

local function line_count(text)
	return #split_lines(text or "")
end

local function trim_start(text)
	return (text or ""):gsub("^%s+", "")
end

local function is_annotation_candidate(line)
	local trimmed = trim_start(line)
	return trimmed ~= ""
		and not vim.startswith(trimmed, "--")
		and not vim.startswith(trimmed, "//")
		and not vim.startswith(trimmed, "#")
		and not vim.startswith(trimmed, "/*")
		and not vim.startswith(trimmed, "*")
end

local function annotation_candidate_lines(params)
	local lines = split_lines(params.text or "")
	local candidates = {}
	local base_line = params.range and params.range.startLine or params.visibleRange and params.visibleRange.startLine or 1

	for index, line in ipairs(lines) do
		if line and is_annotation_candidate(line) then
			table.insert(candidates, { line = base_line + index - 1, text = line })
		end
	end

	return candidates
end

local function parse_positive_integer(text)
	local value = tonumber(text)
	if value and value > 0 and math.floor(value) == value then
		return value
	end
	return nil
end

local function parse_annotation_options(opts)
	local args = opts and opts.fargs or {}
	local parsed = {
		scope = nil,
		max_annotations = nil,
	}

	for _, arg in ipairs(args) do
		local max_annotations = parse_positive_integer(arg)
		if max_annotations then
			parsed.max_annotations = max_annotations
		elseif arg == "line" or arg == "visible" or arg == "buffer" then
			parsed.scope = arg
		else
			return nil, 'unsupported annotation option "' .. tostring(arg) .. '"'
		end
	end

	return parsed, nil
end

local function annotation_context(opts, annotation_options)
	if annotation_options.scope == "line" then
		return context.current_line(), "line"
	end

	if annotation_options.scope == "visible" then
		return context.visible(), "visible"
	end

	if annotation_options.scope == "buffer" then
		return context.buffer(), "buffer"
	end

	local selected_range = context.selected_range(opts)
	if selected_range then
		return selected_range, "range"
	end

	return context.current_line(), "line"
end

local function percentage_budget(candidate_count, percent, minimum, maximum)
	local budget = math.ceil(math.max(0, candidate_count or 0) * percent)
	return math.max(minimum, math.min(maximum, budget))
end

local function annotation_limit(annotation_options, scope_kind, candidate_count)
	if annotation_options.max_annotations then
		return annotation_options.max_annotations
	end
	if scope_kind == "line" then
		return LINE_ANNOTATION_LIMIT
	end
	if scope_kind == "buffer" then
		return percentage_budget(candidate_count, BUFFER_ANNOTATION_PERCENT, BUFFER_ANNOTATION_MIN, BUFFER_ANNOTATION_MAX)
	end
	return percentage_budget(candidate_count, SCOPE_ANNOTATION_PERCENT, SCOPE_ANNOTATION_MIN, SCOPE_ANNOTATION_MAX)
end

function M.clear()
	tracker.cancel("Vantage: cancelled annotation request to")
	walkthrough.disarm()
	annotations.clear_all()
	vim.notify("Vantage: cleared annotations", vim.log.levels.INFO)
end

function M.annotate(opts)
	tracker.cancel("Vantage: cancelled annotation request to")

	local bufnr = vim.api.nvim_get_current_buf()
	local annotation_options, parse_error = parse_annotation_options(opts)
	if not annotation_options then
		vim.notify("Vantage: " .. parse_error, vim.log.levels.ERROR)
		return
	end
	local params, scope_kind = annotation_context(opts, annotation_options)
	params.scopeText = params.text
	params.runtime = (opts and opts.runtime) or state.command_runtime("annotate")
	local candidate_lines = annotation_candidate_lines(params)
	params.maxAnnotations = annotation_limit(annotation_options, scope_kind, #candidate_lines)
	if #candidate_lines > 0 and #candidate_lines <= params.maxAnnotations then
		params.candidateLines = candidate_lines
	end
	local agent = annotation_agent()
	local request_details = {
		method = "annotateRange",
		scope = annotation_options.scope or scope_kind,
		scope_kind = scope_kind,
		selected_line_count = line_count(params.scopeText or params.text or ""),
		max_annotations = params.maxAnnotations,
		candidate_line_count = #candidate_lines,
		timeout_ms = annotation_request_timeout_ms(),
		waiting_message_ms = waiting_message_ms(),
		backend_mode = state.config.backend and state.config.backend.mode or "stdio",
		file_path = params.filePath,
		workspace_root = params.workspaceRoot,
	}
	local token = tracker.begin(agent, request_details, { label = "annotations", waiting_message_ms = waiting_message_ms() })
	tracker.schedule_timeout(token, annotation_request_timeout_ms(), function(status)
		ui.show_markdown("## Error\n\n" .. status.error)
	end)

	local backend_id = backend.request("annotateRange", params, function(response)
		local elapsed = tracker.complete(token)
		if not elapsed then
			return
		end

		if not response or not response.ok then
			local error_message = response_util.error_message(response)
			tracker.set_result_status({
				status = "failed",
				agent = agent.label,
				elapsed = elapsed,
				error = error_message,
				message = "Annotation request failed after " .. elapsed .. ".",
			})
			vim.notify(
				"Vantage: annotation request from " .. agent.label .. " failed after " .. elapsed,
				vim.log.levels.ERROR
			)
			ui.show_markdown(response_util.error_markdown(response))
			return
		end

		local returned_annotations = response.result.annotations or {}
		local received_count = annotation_count(returned_annotations)
		local count = annotations.render(bufnr, returned_annotations)
		if count == 0 then
			local skipped = math.max(0, received_count - count)
			local message
			if received_count == 0 then
				message = "Agent runtime returned no annotations."
			else
				message = "Agent runtime returned "
					.. tostring(received_count)
					.. " annotation(s), but they were not visible in this buffer."
			end
			tracker.set_result_status({
				status = "no_visible_annotations",
				agent = agent.label,
				elapsed = elapsed,
				received = received_count,
				rendered = count,
				skipped = skipped,
				message = message,
			})
			vim.notify(
				"Vantage: "
					.. agent.label
					.. " rendered 0 of "
					.. tostring(received_count)
					.. " returned annotations after "
					.. elapsed,
				vim.log.levels.WARN
			)
			ui.show_markdown(no_annotations_markdown())
			return
		end

		local suffix = count == 1 and "" or "s"
		tracker.set_result_status({
			status = "rendered",
			agent = agent.label,
			elapsed = elapsed,
			received = received_count,
			rendered = count,
			skipped = math.max(0, received_count - count),
			message = "Rendered " .. tostring(count) .. " annotation" .. suffix .. ".",
		})
		vim.notify(
			"Vantage: rendered "
				.. tostring(count)
				.. " annotation"
				.. suffix
				.. " from "
				.. agent.label
				.. " in "
				.. elapsed
				.. telemetry_suffix(response.result),
			vim.log.levels.INFO
		)
	end, {
		on_progress = function(progress)
			tracker.push_progress(token, progress)
		end,
	})
	tracker.set_backend_id(token, backend_id)
end

return M
