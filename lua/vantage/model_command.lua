local backend = require("vantage.backend")
local buffer_edit = require("vantage.buffer_edit")
local search_replace = require("vantage.search_replace")
local context = require("vantage.context")
local paths = require("vantage.paths")
local prompt_authoring = require("vantage.prompt_authoring")
local response_util = require("vantage.response")
local state = require("vantage.state")
local tracker = require("vantage.request_tracker")
local ui = require("vantage.ui")
local walkthrough = require("vantage.walkthrough")

local M = {}

local function format_elapsed(seconds)
	if seconds < 10 then
		return string.format("%.1fs", seconds)
	end
	return tostring(math.floor(seconds + 0.5)) .. "s"
end

local function elapsed_since(started_at)
	return format_elapsed((vim.loop.hrtime() - started_at) / 1000000000)
end

local function notify_requesting()
	vim.notify("Vantage: requesting from " .. state.agent_label() .. "...", vim.log.levels.INFO)
end

local function handle_markdown_response(response, callback, started_at)
	local result, err = response_util.unwrap(response)

	if callback then
		if not result then
			callback(err, nil)
			return
		end
		callback(nil, { markdown = result.markdown or "" })
		return
	end

	if not result then
		vim.notify(
			"Vantage: request failed after " .. elapsed_since(started_at) .. ": " .. response_util.error_message(response),
			vim.log.levels.ERROR
		)
		ui.show_markdown(err)
		return
	end

	vim.notify("Vantage: done in " .. elapsed_since(started_at), vim.log.levels.INFO)
	ui.show_markdown(result.markdown or "")
end

local function request_markdown(method, params, callback)
	if not callback then
		notify_requesting()
	end
	local started_at = vim.loop.hrtime()
	backend.request(method, params, function(response)
		handle_markdown_response(response, callback, started_at)
	end)
end

local function current_agent()
	return { label = state.agent_label() }
end

--- Like request_markdown, but tracked via request_tracker: cancellable
--- through :VantageCancel and visible via :VantageStatus, the same way
--- annotate's requests already are. Used by explain/question, which are the
--- commands that gain a runtime option; request_markdown itself stays as-is
--- for agentCancel/agentSessionReset, which are meta-operations that
--- shouldn't themselves be "the current tracked request".
---@param label string what to call this request in tracker notifications, e.g. "explanation"
local function request_markdown_tracked(method, params, callback, label)
	local agent = current_agent()
	local token = tracker.begin(agent, { method = method }, { label = label, silent = callback ~= nil })

	local backend_id = backend.request(method, params, function(response)
		local elapsed = tracker.complete(token)
		if not elapsed then
			return
		end

		local result, err = response_util.unwrap(response)

		if not result then
			tracker.set_result_status({
				status = "failed",
				agent = agent.label,
				elapsed = elapsed,
				error = response_util.error_message(response),
				message = "Vantage " .. label .. " failed after " .. elapsed .. ".",
			})
			if callback then
				callback(err, nil)
				return
			end
			vim.notify(
				"Vantage: " .. label .. " failed after " .. elapsed .. ": " .. response_util.error_message(response),
				vim.log.levels.ERROR
			)
			ui.show_markdown(err)
			return
		end

		tracker.set_result_status({
			status = "done",
			agent = agent.label,
			elapsed = elapsed,
			message = "Vantage " .. label .. " done in " .. elapsed .. ".",
		})
		if callback then
			callback(nil, { markdown = result.markdown or "" })
			return
		end
		vim.notify("Vantage: done in " .. elapsed, vim.log.levels.INFO)
		ui.show_markdown(result.markdown or "")
	end)
	tracker.set_backend_id(token, backend_id)
end

local function scoped_context(opts)
	return context.scoped(opts)
end

local function request_question(params, question, callback)
	params.selectedText = params.selectedText or params.text
	params.question = question
	request_markdown_tracked("questionSelection", params, callback, "question")
end

---Issues a question request against caller-supplied params, rather than params
---derived from the current buffer. Used by the composition buffer, whose send
---happens while the composition buffer is current but which must attribute the
---request to the code the user was actually working in.
---@param params table context params with `question` already set
---@param callback fun(err: string?, result: table?)? receives the markdown instead of the float
function M.request_question_params(params, callback)
	params.selectedText = params.selectedText or params.text
	request_markdown_tracked("questionSelection", params, callback, "question")
end

---One-line summary of why hunks were skipped, for a notification.
---
---Names the reason and the anchor, because "1 block did not match" is useless
---without knowing which one drifted -- and there is no agent loop to retry it.
---@param failures table[]
---@return string?
local function describe_failures(failures)
	if not failures or #failures == 0 then
		return nil
	end
	local parts = {}
	for _, failure in ipairs(failures) do
		local anchor = (failure.search_line or ""):gsub("^%s+", "")
		table.insert(parts, failure.reason .. ": " .. anchor)
	end
	return table.concat(parts, "; ")
end

---Applies a completion-runtime result in Neovim.
---
---Agent-runtime results bypass this function because Pi's native edit/write tools
---already changed the files. Completion selection scope splices replacement text
---over the known range; completion file scope resolves SEARCH/REPLACE hunks
---against the live buffer.
---@return table? applied { line_count, failures }
---@return string? err
local function apply_edit_result(bufnr, params, result)
	if params.scope ~= "file" then
		return buffer_edit.apply(bufnr, params.range, result.replacementText)
	end

	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil, "The buffer this edit was requested for no longer exists."
	end

	local hunks = result.hunks or {}
	if #hunks == 0 then
		-- The prompt explicitly invites this ("if no edit is needed, return no
		-- blocks at all"), so it is a successful no-op, not a failure.
		return { hunk_count = 0, failures = {}, noop = true }
	end

	local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	local resolved, failures = search_replace.resolve(text, hunks)
	local count = buffer_edit.apply_hunks(bufnr, resolved)

	if count == 0 then
		return nil, describe_failures(failures) or "No edit blocks matched the buffer."
	end
	return { hunk_count = count, failures = failures }
end

local function request_edit(bufnr, params, instruction)
	params.instruction = instruction

	-- Joins the shared tracker so it's cancellable via VantageCancel and
	-- visible via VantageStatus, same as explain/question/annotate.
	local agent = current_agent()
	local token = tracker.begin(agent, { method = "editSelection" }, { label = "edit" })

	local backend_id = backend.request("editSelection", params, function(response)
		local elapsed = tracker.complete(token)
		if not elapsed then
			return
		end

		-- Dispatch on whichever shape arrived rather than predicting it from
		-- `scope`: the protocol supplies `kind` precisely so the client does not
		-- have to guess, and a wrong guess surfaced as an opaque unwrap failure.
		local ok_result = response and response.ok and response.result or nil
		local arrived_kind = type(ok_result) == "table" and ok_result.kind or nil
		local expected_kind
		if params.runtime == "agent" then
			expected_kind = "edit_applied"
		else
			expected_kind = arrived_kind == "edits" and "edits" or "edit"
		end
		local result, err = response_util.unwrap(response, expected_kind)
		if not result then
			tracker.set_result_status({
				status = "failed",
				agent = agent.label,
				elapsed = elapsed,
				error = response_util.error_message(response),
				message = "Vantage edit failed after " .. elapsed .. ".",
			})
			vim.notify(
				"Vantage: edit failed after " .. elapsed .. ": " .. response_util.error_message(response),
				vim.log.levels.ERROR
			)
			ui.show_markdown(err)
			return
		end

		if params.runtime == "agent" then
			-- Pi's native edit/write tools already changed the files. Vantage only
			-- asks Neovim to notice an external change; it never applies model text.
			if vim.api.nvim_buf_is_valid(bufnr) then
				vim.api.nvim_buf_call(bufnr, function()
					vim.cmd("checktime")
				end)
			end
			local summary = result.summary or "Pi completed the requested edit."
			tracker.set_result_status({
				status = "done",
				agent = agent.label,
				elapsed = elapsed,
				message = "Vantage agent edit completed in " .. elapsed .. ".",
			})
			vim.notify("Vantage: " .. summary .. " (" .. elapsed .. ")", vim.log.levels.INFO)
			return
		end

		local applied, apply_err = apply_edit_result(bufnr, params, result)
		if not applied then
			tracker.set_result_status({
				status = "failed",
				agent = agent.label,
				elapsed = elapsed,
				error = tostring(apply_err),
				message = "Vantage edit failed after " .. elapsed .. ".",
			})
			vim.notify("Vantage: edit failed after " .. elapsed .. ": " .. tostring(apply_err), vim.log.levels.ERROR)
			ui.show_markdown("## Error\n\n" .. tostring(apply_err))
			return
		end

		-- Scope decides the unit. `apply_hunks` counts blocks, `apply` counts
		-- lines; rendering both as "line(s)" reported "3 line(s)" for a 3-block,
		-- 40-line edit and understated an unreviewed change.
		local summary
		if applied.noop then
			summary = "Vantage: no edit needed (" .. elapsed .. ")"
		elseif applied.hunk_count then
			summary = "Vantage: applied "
				.. tostring(applied.hunk_count)
				.. " edit block(s) in "
				.. elapsed
		else
			summary = "Vantage: applied edit replacing "
				.. tostring(applied.line_count)
				.. " line(s) in "
				.. elapsed
		end

		-- Report what was skipped. Omitting this made a partial application look
		-- like an unqualified success, contradicting the documented contract that
		-- an unplaceable change is reported rather than guessed at.
		local skipped = describe_failures(applied.failures)
		if skipped then
			summary = summary .. "; " .. tostring(#applied.failures) .. " skipped"
		end

		tracker.set_result_status({
			status = "done",
			agent = agent.label,
			elapsed = elapsed,
			message = summary .. ".",
		})
		vim.notify(summary, skipped and vim.log.levels.WARN or vim.log.levels.INFO)
		if skipped then
			ui.show_markdown("## Edit blocks skipped\n\n- " .. skipped:gsub("; ", "\n- "))
		end
	end)
	tracker.set_backend_id(token, backend_id)
end

function M.explain(opts)
	opts = opts or {}
	local params = scoped_context(opts)
	params.runtime = opts.runtime or state.command_runtime("explain")
	request_markdown_tracked("explainSelection", params, opts.callback, "explanation")
end

function M.question(opts)
	opts = opts or {}
	local params = scoped_context(opts)
	local default_runtime = opts.runtime or state.command_runtime("question")
	prompt_authoring.resolve({
		kind = "question",
		params = params,
		command_opts = opts,
		runtime = default_runtime,
		show_runtime_toggle = true,
		on_submit = function(question, runtime)
			params.runtime = runtime or default_runtime
			request_question(params, question, opts.callback)
		end,
	})
end

---Params for an edit, and the scope they represent.
---
---Completion mode's scope chooses its output format. Agent mode gives Pi the
---selection/current-line context as a starting hint, but Pi owns the complete
---workspace edit and decides which files and ranges need changing.
---
---Completion mode has no tools and cannot iterate, which is the entire reason
---the SEARCH/REPLACE format exists. There a selection keeps its own bounds
---(the destination is already chosen), and no selection means the whole file,
---so the model can designate changes anywhere in it.
---@param opts table? a user-command callback's opts (range/line1/line2)
---@param runtime "agent"|"completion"
---@return table params
---Moves `context`'s `selectedText` onto `scopeText`, the name the edit request
---actually uses -- under file scope the value is the whole buffer, not a
---selection.
local function as_scope_text(params)
	params.scopeText = params.selectedText or params.text
	params.selectedText = nil
	return params
end

local function edit_params(opts, runtime)
	local selected = context.selected_range(opts)

	if runtime ~= "completion" then
		return as_scope_text(selected or context.scoped(opts))
	end

	if selected then
		selected.scope = "selection"
		return as_scope_text(selected)
	end

	-- No selectionSource: the whole file is neither a selection nor a cursor
	-- line, and the field is read nowhere and stripped by the request schema.
	local params = context.line_range(1, vim.api.nvim_buf_line_count(0))
	params.scope = "file"
	return as_scope_text(params)
end

function M.edit(opts)
	opts = opts or {}
	local bufnr = vim.api.nvim_get_current_buf()
	local default_runtime = opts.runtime or state.command_runtime("edit")

	prompt_authoring.resolve({
		kind = "edit",
		-- Scoped params for the prompt buffer's own reference resolution. The
		-- params actually sent are rebuilt at submit time, because the runtime
		-- toggle can change what the scope should be after this point.
		params = context.scoped(opts),
		command_opts = opts,
		runtime = default_runtime,
		show_runtime_toggle = true,
		on_submit = function(instruction, runtime)
			runtime = runtime or default_runtime
			local params = edit_params(opts, runtime)
			params.runtime = runtime

			-- Refuse rather than spend a long call on a request that will fail on
			-- context length or, worse, come back truncated and apply a partial
			-- edit. Naming the two ways forward keeps the refusal actionable.
			local max_lines = ((state.config.commands or {}).edit or {}).max_file_lines
			if params.scope == "file" and max_lines and vim.api.nvim_buf_line_count(bufnr) > max_lines then
				vim.notify(
					"Vantage: file is over "
						.. max_lines
						.. " lines for a whole-file edit. Select a range, or use runtime=agent.",
					vim.log.levels.WARN
				)
				return
			end

			request_edit(bufnr, params, instruction)
		end,
	})
end

local function open_search_results(response, workspace_root, started_at)
	local result, err = response_util.unwrap(response, "locations", "Backend returned an invalid search response.")
	if not result then
		vim.notify(
			"Vantage: search failed after " .. elapsed_since(started_at) .. ": " .. response_util.error_message(response),
			vim.log.levels.ERROR
		)
		ui.show_markdown(err)
		return
	end

	local items = {}
	for _, location in ipairs(result.locations or {}) do
		table.insert(items, {
			filename = paths.resolve(workspace_root, location.filePath or ""),
			lnum = location.startLine or 1,
			col = location.startCharacter or 1,
			text = location.explanation or "",
		})
	end

	vim.fn.setqflist({}, "r", { title = #items == 0 and "Vantage Search: no results" or "Vantage Search", items = items })
	if #items == 0 then
		vim.notify("Vantage: no search results found (" .. elapsed_since(started_at) .. ")", vim.log.levels.INFO)
		return
	end
	vim.notify("Vantage: found " .. tostring(#items) .. " result(s) in " .. elapsed_since(started_at), vim.log.levels.INFO)
	vim.cmd("copen")
end

local function request_search(params, query)
	params.query = query
	params.selectedText = params.selectedText or params.text
	notify_requesting()
	local started_at = vim.loop.hrtime()
	backend.request("searchLocations", params, function(response)
		open_search_results(response, params.workspaceRoot, started_at)
	end)
end

function M.search(opts)
	local params = scoped_context(opts)
	prompt_authoring.resolve({
		kind = "search",
		params = params,
		command_opts = opts,
		empty_message = "Vantage: search requires a prompt",
		on_submit = function(query)
			request_search(params, query)
		end,
	})
end

local function request_walkthrough(params, prompt_text)
	params.prompt = prompt_text
	notify_requesting()
	local started_at = vim.loop.hrtime()
	backend.request("generateWalkthrough", params, function(response)
		local result, err = response_util.unwrap(response, "walkthrough")
		if not result then
			vim.notify(
				"Vantage: walkthrough generation failed after "
					.. elapsed_since(started_at)
					.. ": "
					.. response_util.error_message(response),
				vim.log.levels.ERROR
			)
			ui.show_markdown(err)
			return
		end

		local pointer_count = result.pointerCount or 0
		vim.notify(
			"Vantage: generated walkthrough with "
				.. tostring(pointer_count)
				.. " pointer(s) in "
				.. elapsed_since(started_at),
			vim.log.levels.INFO
		)
		walkthrough.load()
	end)
end

function M.generate_walkthrough(opts)
	local params = scoped_context(opts)
	prompt_authoring.resolve({
		kind = "walkthrough",
		params = params,
		command_opts = opts,
		empty_message = "Vantage: walkthrough generation requires a prompt",
		on_submit = function(prompt_text)
			request_walkthrough(params, prompt_text)
		end,
	})
end

--- Cancels whatever's currently tracked as in flight (explain/question/edit/
--- annotate, whichever runtime served it) and interrupts the persistent
--- agent session, unconditionally -- each half is a safe no-op when there's
--- nothing on that side to cancel.
function M.cancel(opts)
	opts = opts or {}
	tracker.cancel("Vantage: cancelled request to")
	request_markdown("agentCancel", context.current_line(), opts.callback)
end

function M.reset_agent_session(opts)
	opts = opts or {}
	request_markdown("agentSessionReset", context.current_line(), opts.callback)
end

return M
