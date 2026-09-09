local state = require("vantage.state")
local commands = require("vantage.commands")

local M = {
	CommandNames = commands.CommandNames,
}

function M.setup(config)
	state.setup(config)
	commands.register()
end

function M.set_lens(mode, text)
	commands.set_lens(mode, text)
end

function M.get_lens()
	return state.get_lens()
end

function M.clear_lens()
	commands.clear_lens()
end

function M.prompt_lens(mode)
	commands.prompt_lens(mode)
end

function M.explain(opts)
	commands.explain(opts or {})
end

function M.question(opts)
	commands.question(opts or {})
end

function M.edit(opts)
	commands.edit(opts or {})
end

function M.annotate(opts)
	commands.annotate(opts or {})
end

function M.clear_annotations()
	commands.clear_annotations()
end

function M.load_walkthrough()
	commands.load_walkthrough()
end

function M.search(opts)
	commands.search(opts or {})
end

function M.generate_walkthrough(opts)
	commands.generate_walkthrough(opts or {})
end

function M.cancel(opts)
	commands.cancel(opts or {})
end

function M.agent_reset(opts)
	commands.reset_agent_session(opts or {})
end

function M.status()
	commands.show_status()
end

function M.session_output()
	commands.session_output()
end

function M.debug_log()
	commands.debug_log()
end

function M.model(name)
	commands.select_model(name)
end

function M.select_model(name)
	commands.select_model(name)
end

function M.output_to_buffer(split_mode)
	commands.output_to_buffer(split_mode)
end

function M.health()
	commands.health()
end

---Opens or focuses the composition buffer: a persistent markdown split you
---accumulate entries into, then send once with `compose_send`.
function M.compose()
	commands.compose()
end

---Sends the staged composition through `composition.on_send`, or through
---Vantage's own question flow when no `on_send` is configured. Clears and closes
---per `composition.clear_on_send` / `close_on_send`; a failed send leaves the
---content staged.
function M.compose_send()
	return commands.compose_send()
end

---Empties the composition buffer without destroying it.
function M.compose_clear()
	commands.compose_clear()
end

---Appends an entry to the composition buffer, creating and showing it if needed.
---Separation between entries is handled here rather than by callers: pass
---`opts.separation = "blank"` for blank-line separation instead of a `---` rule.
---@param text string
---@param opts { separation?: "rule"|"blank" }?
---@return boolean appended false when `text` is nil or blank
function M.compose_append(text, opts)
	return require("vantage.composition").append(text, opts)
end

---Whether `buf` is Vantage's composition buffer. Use this rather than reading
---`b:vantage_composition` directly -- integrations that scope behavior to the
---composition buffer (completion sources, statusline, keymaps) should depend on
---this predicate.
---@param buf integer? defaults to the current buffer
---@return boolean
function M.is_composition_buffer(buf)
	return require("vantage.composition").is_composition_buffer(buf)
end

---Opens Vantage's floating prompt buffer to collect multi-line input, without
---issuing a request of its own. Intended for integrations that compose their
---own prompt text and then either dispatch it through another Vantage function
---(`vantage.question({ args = text })`) or use it however they like.
---
---The submitted text has `@path` / `/skill` references expanded, resolved
---against `opts.params.workspaceRoot` -- pass `params` (e.g. from
---`require("vantage.context").scoped({})`) if you want that resolution.
---`opts.title` renders a centered caption on the float's border, so a caller
---driving several distinct flows through this one surface can label them.
---`on_submit` is not called when the prompt is cancelled.
---@param opts { on_submit: fun(text: string, runtime: string), kind?: string, title?: string, params?: table, runtime?: string, show_runtime_toggle?: boolean }
---@return integer buf
---@return integer win
function M.prompt(opts)
	return require("vantage.ui.prompt_buffer").open(opts or {})
end

---Formats an `@`-reference the way Vantage's prompt buffer parses them, so
---integrations inserting references stay consistent with that contract.
---Returns nil when `spec.path` is missing or empty.
---@param spec { path: string, start_line?: integer, end_line?: integer }
---@return string? reference
function M.format_reference(spec)
	return require("vantage.ui.prompt_buffer").format_reference(spec)
end

---Recorded prompts, newest first. Defaults to every workspace; pass
---`{ workspace = root }` to scope. Exposed so integrations can build their own
---picker rather than Vantage owning one.
---@param opts { workspace?: string }?
---@return table[] entries
function M.history(opts)
	return require("vantage.history").entries(opts)
end

---`:VantageHistory`. Selects an entry, then replaces a cycle-attached buffer's
---content or yanks to the unnamed register.
function M.history_pick()
	commands.history_pick()
end

---`:VantageHistoryClearWorkspace`.
function M.history_clear_workspace()
	commands.history_clear_workspace()
end

---`:VantageHistoryClearAll`.
function M.history_clear_all()
	commands.history_clear_all()
end

---Toggles monitor mode: a live feed of workspace edits made by something other
---than this Neovim instance. Each changed file opens in the current window with
---the cursor on its first changed hunk. Because opening a file is a Vim jump,
---`<C-o>` and `<C-i>` walk the trail of recent edits natively -- monitor mode
---binds no keys of its own.
---@return boolean active
function M.monitor()
	return commands.monitor()
end

---Recently changed files in the monitor feed, newest first. Exposed so
---integrations can build their own picker rather than Vantage owning one.
---@return table[] entries
function M.monitor_entries()
	return require("vantage.monitor").entries()
end

---The line range of the visual selection that is live right now, or nil when
---not in visual mode. Exposed for integrations that need the range without a
---full context capture -- reading the `'<` / `'>` marks instead is wrong from a
---Lua-function keymap, since those marks hold the *previous* selection.
---@return integer? start_line
---@return integer? end_line
function M.visual_range()
	return require("vantage.visual").live_range()
end

---Context params for the current scope: an explicit command range, else a live
---visual selection, else the cursor line. Exposed so integrations building
---their own prompts can capture the same context Vantage's own commands use.
---@param opts table? a user-command callback's opts (range/line1/line2)
---@return table params
function M.context(opts)
	return require("vantage.context").scoped(opts or {})
end

return M
