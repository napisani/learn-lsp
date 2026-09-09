local hints = require("vantage.ui.hints")
local history = require("vantage.history")
local history_keymap = require("vantage.ui.history_keymap")
local skill_cache = require("vantage.skill_cache")
local state = require("vantage.state")
local ui = require("vantage.ui")
local win_util = require("vantage.ui.window")

local M = {}

local function trim(text)
	return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function keymaps()
	local config = (((state.config.ui or {}).prompt or {}).keymaps or {})
	return {
		submit = win_util.as_list(config.submit or "<CR>"),
		cancel = win_util.as_list(config.cancel or "<Esc>"),
		close = win_util.as_list(config.close or "q"),
		history_prev = win_util.as_list(config.history_prev),
		history_next = win_util.as_list(config.history_next),
		toggle_runtime = win_util.as_list(config.toggle_runtime or "<C-r>"),
	}
end


local function close(buf, win)
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_close(win, true)
	elseif buf and vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_delete(buf, { force = true })
	end
end

local function normalize_path(path)
	return path:gsub("\\", "/"):gsub("^%./", "")
end

local function known_file(root, ref)
	if not root or root == "" then
		return nil
	end
	local candidate = normalize_path(ref)
	if candidate:match("^/") or candidate:match("%.%.") then
		return nil
	end
	local stat = vim.loop.fs_stat(root .. "/" .. candidate)
	if stat and stat.type == "file" then
		return candidate
	end
	return nil
end

local function skill_names(skills)
	local names = {}
	for _, skill in ipairs(skills or {}) do
		if type(skill.name) == "string" then
			names[skill.name] = true
		end
	end
	return names
end

local function references_section(text, params, skills)
	local files = {}
	local seen_files = {}
	for ref in text:gmatch("@([%w%._%-%/%\\]+)") do
		local resolved = known_file(params.workspaceRoot, ref)
		if resolved and not seen_files[resolved] then
			seen_files[resolved] = true
			table.insert(files, resolved)
		end
	end

	local names = skill_names(skills)
	local resolved_skills = {}
	local seen_skills = {}
	for skill in text:gmatch("%f[%s/](/[%w][%w%-]*)") do
		local name = skill:sub(2)
		if names[name] and not seen_skills[name] then
			seen_skills[name] = true
			table.insert(resolved_skills, name)
		end
	end
	for name in text:gmatch("/skill:([%w][%w%-]*)") do
		if names[name] and not seen_skills[name] then
			seen_skills[name] = true
			table.insert(resolved_skills, name)
		end
	end

	if #files == 0 and #resolved_skills == 0 then
		return text
	end

	local lines = { text, "", "## Vantage Prompt References", "" }
	for _, file in ipairs(files) do
		table.insert(lines, "- file: `" .. file .. "`")
	end
	for _, skill in ipairs(resolved_skills) do
		table.insert(lines, "- skill: `skill:" .. skill .. "`")
	end
	return table.concat(lines, "\n")
end

---Formats an `@`-reference for insertion into prompt text.
---
---Deliberately lives next to `references_section` above, which is the parser
---for this same syntax -- emitter and parser have to agree, so they stay
---adjacent. Note that parser matches `@([%w%._%-%/%\\]+)`, which stops at `:`
---and captures no line numbers, so the `lines N-M` suffix is currently
---decorative: readable to a human and to the model, but resolved as a
---file-level reference.
---An absolute `spec.path` is relativized against the workspace root Vantage
---resolves refs against, so integrations do not each invent their own rule --
---a cwd-relative path silently stops matching whenever cwd differs from the
---buffer's project root.
---@param spec { path: string, start_line?: integer, end_line?: integer }
---@return string? reference nil when there is no path to reference
function M.format_reference(spec)
	spec = spec or {}
	local path = spec.path
	if type(path) ~= "string" or trim(path) == "" then
		return nil
	end

	path = normalize_path(trim(path))
	if path:sub(1, 1) == "/" then
		local root = normalize_path(require("vantage.agent_context").workspace_root() or "")
		if root ~= "" and path:sub(1, #root + 1) == root .. "/" then
			path = path:sub(#root + 2)
		end
	end
	if path == "" then
		return nil
	end
	if spec.start_line and spec.end_line then
		if spec.start_line == spec.end_line then
			return string.format("@%s line %s", path, spec.start_line)
		end
		return string.format("@%s lines %s-%s", path, spec.start_line, spec.end_line)
	end

	return "@" .. path
end

---Whether `buf` is a Vantage prompt buffer. Use this rather than reading
---`b:vantage_prompt_buffer` directly -- the raw `pcall(...)`-as-boolean form
---reports true for a buffer where the variable exists and is `false`.
---@param buf integer? defaults to the current buffer
---@return boolean
function M.is_prompt_buffer(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return false
	end
	local ok, value = pcall(vim.api.nvim_buf_get_var, buf, "vantage_prompt_buffer")
	return ok and value == true
end

function M.expand_references(text, params, callback)
	skill_cache.list(function(skills)
		callback(references_section(text, params or {}, skills))
	end)
end

function M.open(opts)
	opts = opts or {}
	local kind = opts.kind or "prompt"
	local params = opts.params or {}
	local on_submit = opts.on_submit or function() end
	local show_runtime_toggle = opts.show_runtime_toggle == true
	local current_runtime = opts.runtime or "agent"
	local title = opts.title and trim(opts.title) ~= "" and trim(opts.title) or nil

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_name(buf, "VantagePrompt")
	vim.api.nvim_buf_set_var(buf, "vantage_prompt_buffer", true)
	vim.api.nvim_buf_set_var(buf, "vantage_prompt_kind", kind)
	-- The workspace this surface belongs to. Vantage's scratch buffers have no
	-- path, so a consumer resolving a root from the buffer itself would get the
	-- cwd's root rather than the one the prompt is about.
	vim.api.nvim_buf_set_var(buf, "vantage_workspace_root", params.workspaceRoot or "")
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })

	local win = ui.open_float(buf, { height = 0.42, line_count = 12 })
	win_util.apply_readable_options(win)

	local maps = keymaps()

	local reset_cycle = history_keymap.attach(buf, {
		keymaps = maps,
		workspace = function()
			return params.workspaceRoot or ""
		end,
	})

	-- Title and footer are applied in one nvim_win_set_config call: setting only
	-- one of them clears the other on a float.
	local function refresh_footer()
		local segments = {}
		if show_runtime_toggle then
			table.insert(segments, { label = "agent", key = maps.toggle_runtime[1], checked = current_runtime == "agent" })
		end
		table.insert(segments, { label = "submit", key = maps.submit[1] })

		local config = {}
		local footer = hints.footer(segments)
		if footer then
			config.footer = footer
			config.footer_pos = "right"
		end
		if title then
			config.title = " " .. title .. " "
			config.title_pos = "center"
		end

		if next(config) and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_set_config(win, config)
		end
	end

	refresh_footer()

	-- Reference expansion is async (it asks the backend for the skill list), and
	-- this buffer is bufhidden=wipe. Closing before the callback resolves would
	-- destroy the typed text with nothing to recover it if the backend never
	-- answers, so the float stays up until expansion returns.
	local submitting = false

	---Records the raw buffer text. Deliberately the pre-expansion text: recalling
	---an expanded prompt would carry its "## Vantage Prompt References" block back
	---in, and the next submit would append a second one. pcall'd because history
	---is a convenience and must never break a submit.
	local function record(text, submitted)
		pcall(history.record, {
			kind = kind,
			text = text,
			submitted = submitted,
			workspaceRoot = params.workspaceRoot,
			filePath = params.filePath,
		})
	end

	-- Draft rescue hangs off BufWipeout rather than the cancel keymap. This float
	-- is bufhidden=wipe, so :q, :bd, <C-w>c, :only, a window-managing plugin, or
	-- any programmatic close destroys the text too -- binding the rescue to one
	-- keymap covered only the tidiest exit.
	local recorded = false
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function()
			if recorded then
				return
			end
			local text = trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
			if text ~= "" then
				record(text, false)
			end
		end,
	})

	local function submit()
		if submitting then
			return
		end
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local text = trim(table.concat(lines, "\n"))
		if text == "" then
			vim.notify("Vantage prompt is empty", vim.log.levels.WARN)
			return
		end
		record(text, true)
		recorded = true
		reset_cycle()
		submitting = true
		M.expand_references(text, params, function(expanded)
			submitting = false
			close(buf, win)
			on_submit(expanded, current_runtime)
		end)
	end

	local function cancel()
		close(buf, win)
	end

	local function toggle_runtime()
		current_runtime = current_runtime == "agent" and "completion" or "agent"
		refresh_footer()
	end

	for _, lhs in ipairs(maps.submit) do
		vim.keymap.set({ "n", "i" }, lhs, submit, { buffer = buf, silent = true, desc = "Submit Vantage prompt" })
	end
	-- Cancel/close bind in normal mode only, deliberately. The default cancel
	-- key is <Esc>, and the prompt opens with startinsert -- binding it in
	-- insert mode too would make <Esc> close the float instead of leaving
	-- insert mode, so normal mode (and every normal-mode-only keymap in this
	-- buffer) would be unreachable.
	for _, lhs in ipairs(maps.cancel) do
		vim.keymap.set("n", lhs, cancel, { buffer = buf, silent = true, desc = "Cancel Vantage prompt" })
	end
	for _, lhs in ipairs(maps.close) do
		vim.keymap.set("n", lhs, cancel, { buffer = buf, silent = true, desc = "Close Vantage prompt" })
	end
	if show_runtime_toggle then
		for _, lhs in ipairs(maps.toggle_runtime) do
			vim.keymap.set(
				{ "n", "i" },
				lhs,
				toggle_runtime,
				{ buffer = buf, silent = true, desc = "Toggle Vantage prompt runtime (agent/completion)" }
			)
		end
	end

	vim.schedule(function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_set_current_win(win)
			vim.cmd("startinsert")
		end
	end)
	return buf, win
end

return M
