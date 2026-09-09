-- Composition buffer: a persistent staging area you accumulate into over time,
-- then send once.
--
-- Distinct from `ui/prompt_buffer.lua`, which is an ephemeral float that collects
-- a single prompt and hands it straight to a callback. This is a long-lived
-- markdown split you append references, selections, and instructions to across
-- many actions before dispatching the whole thing.
--
-- The destination is deliberately not Vantage's business: `composition.on_send`
-- receives the staged text and can route it anywhere. With no `on_send`
-- configured it falls back to Vantage's own question flow, so the feature works
-- out of the box.
local history = require("vantage.history")
local history_keymap = require("vantage.ui.history_keymap")
local state = require("vantage.state")
local win_util = require("vantage.ui.window")

local M = {}

local BUFFER_NAME = "VantageComposition"

-- Public, documented contract: integrations (e.g. completion sources scoped to
-- the composition buffer) detect it with this variable, or preferably via
-- `is_composition_buffer`.
local BUFFER_VAR = "vantage_composition"

---@type integer|nil
local bufnr = nil

-- Context of the buffer the user was actually working in when they last staged
-- something. The no-`on_send` fallback needs it because by the time `send()`
-- runs the current buffer is usually the composition buffer itself, so asking
-- the model about "the current file" would ask about the staging scratchpad.
---@type table|nil
local origin_context = nil


---Returns the history walk to "newest". Set when the buffer is created.
---@type fun()
local reset_cycle = function() end

local function config()
	return state.config.composition or {}
end

local function ui_config()
	return ((state.config.ui or {}).composition or {})
end

-- Defaults live in state.default_config(); nothing is restated here so there is
-- one source of truth for what `<C-g>`/`q` are.
local function keymaps()
	return win_util.keymaps(ui_config().keymaps)
end

---Whether `buf` is the composition buffer.
---@param buf integer? defaults to the current buffer
---@return boolean
function M.is_composition_buffer(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return false
	end
	local ok, value = pcall(vim.api.nvim_buf_get_var, buf, BUFFER_VAR)
	return ok and value == true
end

---Recovers the buffer handle if it was lost. Only works because the buffer is
---created with `bufhidden = "hide"` -- under "wipe" a hidden buffer is already
---destroyed and there would be nothing to find.
---@return integer? buf
local function find_buffer()
	if bufnr and M.is_composition_buffer(bufnr) then
		return bufnr
	end
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if M.is_composition_buffer(buf) then
			bufnr = buf
			return buf
		end
	end
	bufnr = nil
	return nil
end

---The workspace this buffer's history belongs to. Shared by `send()` and the
---cycle callback so the key entries are *recorded* under cannot diverge from the
---key cycling *filters* on -- when it did, an entry sent from a freshly opened
---composition was invisible to <Up> in the buffer that produced it.
---@return string
local function history_workspace()
	local from_origin = (origin_context or {}).workspaceRoot
	if from_origin and from_origin ~= "" then
		return from_origin
	end

	-- Stamped when the buffer was created, while the user's own file was still
	-- current. Resolving from the composition buffer instead would yield the
	-- cwd's root, which is not the project the prompt is about.
	local buf = find_buffer()
	if buf then
		local ok, root = pcall(vim.api.nvim_buf_get_var, buf, "vantage_workspace_root")
		if ok and type(root) == "string" and root ~= "" then
			return root
		end
	end

	return require("vantage.agent_context").workspace_root() or ""
end

---Records which project the user is working in, whenever they reach the
---composition buffer from a real one. Re-stamped rather than set once at
---creation: this buffer is a singleton that outlives any single project, so a
---creation-time value goes stale the moment the user switches repos.
---@param buf integer the composition buffer
local function remember_origin(buf)
	if M.is_composition_buffer(vim.api.nvim_get_current_buf()) then
		return
	end
	origin_context = require("vantage.context").scoped({})
	pcall(vim.api.nvim_buf_set_var, buf, "vantage_workspace_root", origin_context.workspaceRoot or "")
end

local function split_height()
	local cfg = ui_config()
	return math.max(cfg.min_height, math.min(cfg.max_height, math.floor(vim.o.lines * cfg.height)))
end

---Binds (or rebinds) the history cycle keys. Separate from `bind_keymaps` so
---`refresh` can re-derive them from new config; `attach` deletes its own prior
---maps, so calling this twice is safe.
---@param buf integer
local function bind_history(buf)
	reset_cycle = history_keymap.attach(buf, {
		keymaps = keymaps(),
		workspace = history_workspace,
	})
end

---Window presentation, reapplied on every show() so a window the user opened
---themselves (`:b VantageComposition`) is dressed the same as one we split.
local function dress_window(win)
	win_util.apply_readable_options(win)
	local maps = keymaps()
	win_util.apply_statusline_hint(win, {
		{ label = "send", key = maps.send[1] },
		{ label = "close", key = maps.close[1] },
	})
end

local function bind_keymaps(buf)
	local maps = keymaps()

	-- Idempotent: refresh() re-binds from current config, so drop whatever this
	-- buffer had before rather than leaving stale keys mapped.
	for _, mode in ipairs({ "n", "i" }) do
		for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
			if map.desc and map.desc:match("^Send Vantage composition$") or (map.desc or ""):match("^Close Vantage composition") then
				pcall(vim.keymap.del, mode, map.lhs, { buffer = buf })
			end
		end
	end

	for _, lhs in ipairs(maps.send) do
		vim.keymap.set({ "n", "i" }, lhs, function()
			M.send()
		end, { buffer = buf, silent = true, desc = "Send Vantage composition" })
	end

	-- Normal mode only, same rule as the prompt buffer: this is a buffer the
	-- user types prose into, so insert-mode keys must stay literal.
	for _, lhs in ipairs(maps.close) do
		vim.keymap.set("n", lhs, function()
			M.close()
		end, { buffer = buf, silent = true, desc = "Close Vantage composition window" })
	end
end

---Shows the buffer in a bottom split, reusing its window when already visible.
---
---`opts.focus` defaults to false, deliberately. Appending must not move the
---cursor out of the user's code: staging is something you do *while* working,
---and a focus steal means the next action captures context from the composition
---buffer instead of the file you were editing.
---@param buf integer
---@param opts { focus?: boolean }?
---@return integer win
local function show(buf, opts)
	opts = opts or {}
	local win = win_util.window_in_current_tabpage(buf)
	if win then
		dress_window(win)
		if opts.focus then
			vim.api.nvim_set_current_win(win)
		end
		return win
	end

	local previous = vim.api.nvim_get_current_win()
	win = win_util.open_in_split(buf, "rightbelow split")
	vim.api.nvim_win_set_height(win, split_height())
	dress_window(win)

	if not opts.focus and vim.api.nvim_win_is_valid(previous) then
		vim.api.nvim_set_current_win(previous)
	end
	return win
end

---The composition buffer, created if it does not exist yet.
---@return integer buf
function M.get_or_create_buffer()
	local existing = find_buffer()
	if existing then
		return existing
	end

	local buf = vim.api.nvim_create_buf(false, true)
	bufnr = buf

	vim.bo[buf].buflisted = false
	vim.bo[buf].buftype = "nofile"
	-- "hide", not "wipe": staged work must survive closing the window.
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].modifiable = true
	pcall(vim.api.nvim_buf_set_name, buf, BUFFER_NAME)
	vim.api.nvim_buf_set_var(buf, BUFFER_VAR, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })

	bind_keymaps(buf)

	bind_history(buf)

	-- The buffer is `nofile`/`noswapfile` and never `modified`, so Neovim exits
	-- without its usual unsaved-changes prompt. Warn explicitly rather than
	-- silently discarding a session's worth of staged work.
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("VantageCompositionExit", { clear = true }),
		callback = function()
			if not M.is_empty() then
				local lines = #vim.split(M.content(), "\n", { plain = true })
				vim.notify(
					"Vantage: exiting with " .. lines .. " line(s) still staged in the composition buffer",
					vim.log.levels.WARN
				)
			end
		end,
	})

	return buf
end

---Re-applies keymaps and window presentation from current config. Called by
---`state.setup` so a second `setup()` with different keymaps takes effect on the
---long-lived buffer instead of leaving it bound to the old keys while the
---statusline advertises the new ones.
function M.refresh()
	local buf = find_buffer()
	if not buf then
		return
	end
	bind_keymaps(buf)
	bind_history(buf)
	local win = win_util.window_in_current_tabpage(buf)
	if win then
		dress_window(win)
	end
end

---@return integer? buf nil when no composition buffer exists yet
function M.get_bufnr()
	return find_buffer()
end

---The staged text, trimmed. Empty string when there is nothing staged.
---@return string
function M.content()
	local buf = find_buffer()
	if not buf then
		return ""
	end
	return vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
end

---@return boolean
function M.is_empty()
	return M.content() == ""
end

---Toggles the composition window: opens and focuses it when hidden, closes it
---when visible.
---
---This is the only thing that both shows and hides the buffer. Appending stages
---silently, so the window appears when you ask for it rather than every time
---something is added. Closing only hides -- the content persists.
---@return integer buf
---@return integer? win nil when the toggle closed the window
function M.open()
	local buf = M.get_or_create_buffer()
	remember_origin(buf)

	if win_util.window_in_current_tabpage(buf) then
		M.close()
		return buf, nil
	end

	return buf, show(buf, { focus = true })
end

---Appends an entry, owning separation so callers do not hand-roll it.
---
---Into an empty buffer the text becomes the content. Into a non-empty buffer it
---is preceded by the configured separator rule, or by a blank line only when
---`opts.separation` is "blank" (used for reference payloads, which read better
---as a continuous list than as separate entries).
---
---Note `opts.separation` selects a *style*; the rule text itself is
---`composition.separator` in config. They were one name with two types, which
---meant a per-call string was silently ignored.
---@param text string
---@param opts { separation?: "rule"|"blank" }?
---@return boolean appended
function M.append(text, opts)
	opts = opts or {}
	if type(text) ~= "string" or vim.trim(text) == "" then
		return false
	end

	local buf = M.get_or_create_buffer()

	-- Capture where the user is working *before* show() can put a composition
	-- window on screen, so a later send is attributed to their code and not to
	-- the staging buffer.
	remember_origin(buf)

	local body = text:gsub("%s+$", "")
	local was_empty = M.is_empty()

	local separation = opts.separation or "rule"
	if separation ~= "rule" and separation ~= "blank" then
		vim.notify(
			'Vantage: unknown composition separation "' .. tostring(separation) .. '" (expected "rule" or "blank")',
			vim.log.levels.WARN
		)
		separation = "rule"
	end

	local prefix = ""
	if not was_empty then
		prefix = separation == "blank" and "\n" or ("\n" .. config().separator .. "\n\n")
	end

	vim.bo[buf].modifiable = true
	local chunk = vim.split(prefix .. body, "\n", { plain = true })
	if was_empty then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, chunk)
	else
		local count = vim.api.nvim_buf_line_count(buf)
		vim.api.nvim_buf_set_lines(buf, count, count, false, chunk)
	end

	-- The walk's draft snapshot is now stale: cycling back would replace this
	-- freshly appended text with what the buffer held before the walk started.
	reset_cycle()

	-- Deliberately does not show the buffer. Staging happens constantly while
	-- you work, and a split appearing on every append is disruptive; visibility
	-- is the toggle's job. Notify instead so the action is not silent.
	local entries = select(2, M.content():gsub("\n" .. vim.pesc(config().separator) .. "\n", "")) + 1
	vim.notify(
		"Vantage composition: staged (" .. entries .. " entr" .. (entries == 1 and "y" or "ies") .. ")",
		vim.log.levels.INFO
	)
	return true
end

---Records the context to attribute a later send to. Called by `append` before
---the composition window can steal the current buffer.
---@param ctx table? context params, as returned by `vantage.context()`
function M.set_origin_context(ctx)
	origin_context = ctx
end

---Empties the buffer without destroying it, so the handle and keymaps survive.
function M.clear()
	local buf = find_buffer()
	if not buf then
		return
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
	reset_cycle()
end

---Closes the composition window. The buffer and its content persist.
function M.close()
	local buf = find_buffer()
	if not buf then
		return
	end
	local win = win_util.window_in_current_tabpage(buf)
	if win and vim.api.nvim_win_is_valid(win) then
		local closed = pcall(vim.api.nvim_win_close, win, false)
		if not closed then
			-- Last window in the tabpage: closing is impossible, so show the
			-- alternate buffer rather than appearing to do nothing.
			local switched = pcall(vim.cmd, "buffer #")
			if not switched then
				vim.notify("Vantage composition is the last window; cannot close it", vim.log.levels.WARN)
			end
		end
	end
end

---Sends the staged text.
---
---Routes through `composition.on_send` when configured; otherwise falls back to
---Vantage's own question flow so the feature is useful unconfigured. A literal
---`false` from `on_send` means the send failed, and staged work is left alone --
---clearing on failure would lose it.
---@return boolean sent
function M.send()
	local text = M.content()
	if text == "" then
		vim.notify("Vantage composition is empty", vim.log.levels.WARN)
		return false
	end

	local cfg = config()

	-- Recorded before dispatch: a send that fails should still leave the composed
	-- text recallable. pcall'd so history can never break a send.
	pcall(history.record, {
		kind = "composition",
		text = text,
		submitted = true,
		workspaceRoot = history_workspace(),
	})
	reset_cycle()

	-- A misplaced or mistyped on_send (it is easy to nest under `ui.composition`
	-- by mistake) must not silently redirect staged content to the model.
	if cfg.on_send ~= nil and type(cfg.on_send) ~= "function" then
		vim.notify(
			"Vantage: composition.on_send must be a function, got " .. type(cfg.on_send) .. "; refusing to send",
			vim.log.levels.ERROR
		)
		return false
	end

	if type(cfg.on_send) == "function" then
		if cfg.on_send(text) == false then
			return false
		end
		M.finish_send()
		return true
	end

	-- No destination configured: ask Vantage itself. Scoped to the buffer the
	-- user was working in, not the composition buffer, and only cleared once the
	-- request actually comes back.
	vim.notify("Vantage: composition -> Vantage agent (no composition.on_send configured)", vim.log.levels.INFO)

	local params = vim.tbl_extend("force", origin_context or require("vantage.context").scoped({}), {
		question = text,
	})
	params.selectedText = params.selectedText or params.text

	require("vantage.model_command").request_question_params(params, function(err, result)
		if err then
			require("vantage.ui").show_markdown(err)
			return
		end
		-- The callback form suppresses the default float, so render it here.
		require("vantage.ui").show_markdown(result and result.markdown or "")
		M.finish_send()
	end)
	return true
end

---Clears and/or closes per config after a send is known to have succeeded.
function M.finish_send()
	local cfg = config()
	if cfg.clear_on_send ~= false then
		M.clear()
	end
	if cfg.close_on_send ~= false then
		M.close()
	end
	return true
end

return M
