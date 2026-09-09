local annotation_command = require("vantage.annotation_command")
local agent_context = require("vantage.agent_context")
local backend = require("vantage.backend")
local composition = require("vantage.composition")
local history = require("vantage.history")
local CommandNames = require("vantage.command_names")
local context = require("vantage.context")
local debug_log = require("vantage.debug_log")
local input_ui = require("vantage.input")
local model_command = require("vantage.model_command")
local monitor = require("vantage.monitor")
local response_util = require("vantage.response")
local runtime_option = require("vantage.runtime_option")
local tracker = require("vantage.request_tracker")
local state = require("vantage.state")
local session_output = require("vantage.session_output")
local status_view = require("vantage.status")
local ui = require("vantage.ui")
local walkthrough = require("vantage.walkthrough")

local M = {
	CommandNames = CommandNames,
}

local function trim(text)
	return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

--- The currently-tracked request's status (whichever command started it --
--- explain/question/edit/annotate), for :VantageStatus.
function M.request_status()
	return tracker.status()
end

function M.agent_context_status()
	return agent_context.snapshot()
end

local function agent_status_markdown(response)
	local result = response_util.unwrap(response)
	if result and result.markdown then
		return result.markdown
	end
	return "## Vantage Agent Session\n\n### Error\n\n" .. tostring(response_util.error_message(response))
end

function M.show_status()
	backend.request("agentSessionStatus", context.current_line(), function(response)
		ui.show_markdown(status_view.combined({
			agent_markdown = agent_status_markdown(response),
			agent_context = M.agent_context_status(),
			request = M.request_status(),
		}))
		vim.notify("Vantage status shown", vim.log.levels.INFO)
	end)
end

function M.set_lens(mode, text)
	state.set_lens(mode, text)
end

local function prompt_lens(mode)
	local active_lens = state.get_lens()
	local default = active_lens and active_lens.mode == mode and active_lens.text or ""
	input_ui.prompt("lens", { default = default }, function(input)
		local text = trim(input)
		if text == "" then
			return
		end
		M.set_lens(mode, text)
	end)
end

function M.prompt_lens(mode)
	prompt_lens(mode or "general")
end

function M.clear_lens()
	state.clear_lens()
end

function M.explain(opts)
	model_command.explain(opts)
end

function M.question(opts)
	model_command.question(opts)
end

function M.edit(opts)
	model_command.edit(opts)
end

function M.clear_annotations()
	annotation_command.clear()
end

function M.annotate(opts)
	annotation_command.annotate(opts)
end

function M.load_walkthrough()
	walkthrough.load()
end

function M.search(opts)
	model_command.search(opts)
end

function M.generate_walkthrough(opts)
	model_command.generate_walkthrough(opts)
end

function M.cancel(opts)
	model_command.cancel(opts)
end

function M.reset_agent_session(opts)
	model_command.reset_agent_session(opts)
end

function M.session_output()
	session_output.open()
end

function M.debug_log()
	debug_log.open()
end

function M.health()
	vim.cmd("checkhealth vantage")
end

function M.output_to_buffer(split_mode)
	ui.promote_last_float(split_mode)
end

function M.compose()
	composition.open()
end

function M.compose_send()
	return composition.send()
end

function M.compose_clear()
	composition.clear()
end

---Whether `buf` is one of Vantage's own authoring surfaces.
---@param buf integer
---@return boolean
local function is_vantage_surface(buf)
	return require("vantage.ui.prompt_buffer").is_prompt_buffer(buf) or composition.is_composition_buffer(buf)
end

---The workspace to scope history to.
---
---Vantage's scratch surfaces stamp `b:vantage_workspace_root` with the root they
---were opened against, because resolving a root from a pathless buffer yields
---the cwd's root instead. Everything else falls back to `agent_context`, which
---itself falls back to cwd and never returns nothing. An earlier version used
---"the workspace of the newest entry" here, which meant a scoped clear run from
---a prompt float could purge a *different* project's history.
---@return string
local function current_workspace()
	local buf = vim.api.nvim_get_current_buf()
	local ok, root = pcall(vim.api.nvim_buf_get_var, buf, "vantage_workspace_root")
	if ok and type(root) == "string" and root ~= "" then
		return root
	end
	return require("vantage.agent_context").workspace_root() or ""
end

---Presents history via vim.ui.select. The chosen entry replaces a cycle-attached
---buffer's content when one is focused; otherwise it goes to the unnamed
---register, so a selection is never silently discarded.
function M.history_pick()
	local entries = history.entries({ workspace = current_workspace() })
	if #entries == 0 then
		vim.notify("Vantage: no prompt history for this workspace", vim.log.levels.INFO)
		return
	end

	local labels = {}
	for _, entry in ipairs(entries) do
		local first_line = vim.split(entry.text, "\n", { plain = true })[1] or ""
		local mark = entry.submitted and " " or "~"
		table.insert(labels, string.format("%s[%s] %s", mark, entry.kind, first_line))
	end

	vim.ui.select(labels, { prompt = "Vantage prompt history" }, function(_, index)
		if not index then
			return
		end
		local text = entries[index].text
		local buf = vim.api.nvim_get_current_buf()
		if is_vantage_surface(buf) then
			require("vantage.ui.window").replace_buffer(buf, text)
			return
		end

		vim.fn.setreg("", text)
		vim.notify("Vantage: prompt yanked to the unnamed register", vim.log.levels.INFO)
	end)
end

function M.history_clear_workspace()
	local removed = history.clear({ workspace = current_workspace() })
	vim.notify("Vantage: cleared " .. removed .. " history entr" .. (removed == 1 and "y" or "ies") .. " for this workspace", vim.log.levels.INFO)
end

function M.history_clear_all()
	local removed = history.clear()
	vim.notify("Vantage: cleared all " .. removed .. " history entr" .. (removed == 1 and "y" or "ies"), vim.log.levels.INFO)
end

function M.select_model(name)
	if name then
		local ok, label = state.select_model(name)
		if not ok then
			vim.notify("Vantage: " .. label, vim.log.levels.ERROR)
			return
		end
		-- Reset the buddy session since Pi sessions are model-bound
		model_command.reset_agent_session()
		vim.notify("Vantage: switched to " .. label, vim.log.levels.INFO)
		return
	end

	-- No args: open picker
	local models = state.config.agent and state.config.agent.models or {}
	if #models == 0 then
		vim.notify("Vantage: no models configured", vim.log.levels.WARN)
		return
	end

	local current = state.current_model
	local labels = {}
	for _, m in ipairs(models) do
		local marker = (current and m.name == current.name) and " *" or ""
		table.insert(labels, m.name .. " (" .. m.provider .. "/" .. m.model .. ")" .. marker)
	end

	vim.ui.select(labels, {
		prompt = "Vantage model:",
	}, function(choice)
		if not choice then
			return
		end
		-- Extract name from "name (provider/model)" or "name (provider/model) *"
		local name = choice:match("^(.-)%s*%(")
		if name then
			M.select_model(name)
		end
	end)
end

local function recreate_command(name, command, opts)
	pcall(vim.api.nvim_del_user_command, name)
	vim.api.nvim_create_user_command(name, command, opts or {})
end

local function delete_commands(names)
	for _, name in ipairs(names) do
		pcall(vim.api.nvim_del_user_command, name)
	end
end

--- Wraps a user-command handler to first extract a `runtime=` token from its
--- args, setting `opts.runtime` before calling `handler`. Notifies and
--- aborts on an invalid runtime value instead of passing it through.
local function with_runtime_option(handler)
	return function(opts)
		local runtime, remaining_opts, err = runtime_option.extract(opts)
		if err then
			vim.notify("Vantage: " .. err, vim.log.levels.ERROR)
			return
		end
		remaining_opts.runtime = runtime
		handler(remaining_opts)
	end
end

---Toggles monitor mode: a live feed of workspace edits made by something other
---than this Neovim instance. Wiring lives here rather than in `monitor.lua`,
---which stays free of any knowledge of presentation or git.
---@return boolean active
function M.monitor()
	if monitor.is_active() then
		monitor.stop()
		vim.notify("Vantage monitor stopped", vim.log.levels.INFO)
		return false
	end

	local monitor_config = state.config.monitor or {}
	local root = current_workspace()

	local started = monitor.start({
		workspace = root,
		source = monitor.resolve_source(root),
		-- The built-in renderer opens the file in the current window, which Vim
		-- records as a jump -- so <C-o>/<C-i> walk recent edits with no keymaps
		-- of ours. A configured `render` replaces that wholesale.
		render = monitor_config.render or require("vantage.ui.navigate").open,
		-- Only a custom renderer can have something to tear down; opening a
		-- buffer leaves nothing behind. Same key name end to end, so grepping
		-- `on_stop` finds the whole path.
		on_stop = monitor_config.on_stop,
	})

	if started then
		vim.notify("Vantage monitor watching " .. root, vim.log.levels.INFO)
	end
	return started
end

function M.register()
	recreate_command(CommandNames.set_lens, function(opts)
		local active_lens = state.get_lens()
		local mode = opts.fargs[1] or (active_lens and active_lens.mode) or "general"
		local text = trim(table.concat(vim.list_slice(opts.fargs, 2), " "))
		if text == "" then
			prompt_lens(mode)
			return
		end
		M.set_lens(mode, text)
	end, { nargs = "*" })

	recreate_command(CommandNames.clear_lens, function()
		M.clear_lens()
	end)

	delete_commands({ "VantageExplainLine", "VantageExplainSelection" })
	recreate_command(CommandNames.explain, with_runtime_option(function(opts)
		M.explain(opts)
	end), { range = true, nargs = "*" })

	recreate_command(CommandNames.question, with_runtime_option(function(opts)
		M.question(opts)
	end), { range = true, nargs = "*" })

	recreate_command(CommandNames.edit, with_runtime_option(function(opts)
		M.edit(opts)
	end), { range = true, nargs = "*" })

	delete_commands({ "VantageToggleAnnotations" })
	recreate_command(CommandNames.annotate, with_runtime_option(function(opts)
		M.annotate(opts)
	end), { range = true, nargs = "*" })

	recreate_command(CommandNames.annotation_clear, function()
		M.clear_annotations()
	end)

	recreate_command(CommandNames.load_walkthrough, function()
		M.load_walkthrough()
	end)

	recreate_command(CommandNames.status, function()
		M.show_status()
	end)

	recreate_command(CommandNames.session_output, function()
		M.session_output()
	end)

	recreate_command(CommandNames.search, function(opts)
		M.search(opts)
	end, { range = true, nargs = "*" })

	recreate_command(CommandNames.generate_walkthrough, function(opts)
		M.generate_walkthrough(opts)
	end, { range = true, nargs = "*" })

	recreate_command(CommandNames.cancel, function()
		M.cancel()
	end)

	recreate_command(CommandNames.agent_reset, function()
		M.reset_agent_session()
	end)

	recreate_command(CommandNames.debug_log, function()
		M.debug_log()
	end)

	recreate_command(CommandNames.model, function(opts)
		local name = opts.args ~= "" and opts.args or nil
		M.select_model(name)
	end, { nargs = "?" })

	recreate_command(CommandNames.output_to_buffer, function(opts)
		local split_mode = opts.args == "vsplit" and "vsplit" or "split"
		M.output_to_buffer(split_mode)
	end, { nargs = "?" })

	recreate_command(CommandNames.compose, function()
		M.compose()
	end)

	recreate_command(CommandNames.compose_send, function()
		M.compose_send()
	end)

	recreate_command(CommandNames.compose_clear, function()
		M.compose_clear()
	end)

	recreate_command(CommandNames.history, function()
		M.history_pick()
	end)

	recreate_command(CommandNames.history_clear_workspace, function()
		M.history_clear_workspace()
	end)

	recreate_command(CommandNames.history_clear_all, function()
		M.history_clear_all()
	end)

	recreate_command(CommandNames.monitor, function()
		M.monitor()
	end)

	recreate_command(CommandNames.health, function()
		M.health()
	end)
end

return M
