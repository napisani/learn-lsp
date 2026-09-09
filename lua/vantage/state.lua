local M = {}

local function plugin_root()
	local source = debug.getinfo(1, "S").source:gsub("^@", "")
	return vim.fn.fnamemodify(source, ":p:h:h:h")
end

---@class VantageBackendConfig
---@field mode? "stdio"|"development"
---@field command? string[]

---@class VantageAgentOptions
---@field [string] any Pi options bag. Vantage does not add model-option defaults.

---@class VantageAgentAuthConfig
---@field path? string Path to a Pi OAuth auth.json file. Relative paths resolve from the workspace root in the backend.

---@class VantageAgentSessionOutputConfig
---@field history_limit? integer

---@class VantageModelConfig
---@field name string Unique name for this model preset.
---@field provider string Pi provider name (e.g. "openai", "anthropic").
---@field model string Pi model name (e.g. "gpt-4o-mini", "claude-sonnet-4-20250514").
---@field apiKey? string Optional per-model API key override.
---@field options? VantageAgentOptions Per-model options that override shared agent.options.

---@class VantageAgentConfig
---@field runtime? "pi"|"adjacent"|"adjacent-or-pi"|"development" Adjacent-or-pi probes once on the first backend command and keeps that choice until backend restart.
---@field adjacent? { socket_path?: string } Optional explicit Unix socket; otherwise discover Pi in the same workspace.
---@field models? VantageModelConfig[] List of named model presets.
---@field default_model? string Name of the model preset to use on startup.
---@field auth? VantageAgentAuthConfig
---@field options? VantageAgentOptions Options for the agent runtime.
---@field session_output? VantageAgentSessionOutputConfig

---@class VantageCompletionConfig
---@field options? VantageAgentOptions Options for the completion runtime.

---@class VantageCommandConfig
---@field include_lens? boolean
---@field max_file_lines? integer Edit only: refuse a whole-file completion edit above this many lines. Default 2000.
---@field options? VantageAgentOptions
---@field runtime? "agent"|"completion" "agent" (default) runs the full tool-using agent; "completion" runs a single one-shot completion call with no tools/session. Only explain/question/annotate honor this — edit stays agent-only and ignores it.

---@class VantageSearchCommandConfig: VantageCommandConfig

---@class VantageAnnotateCommandConfig: VantageCommandConfig
---@field waiting_message_ms? integer

---@class VantageCommandsConfig
---@field explain? VantageCommandConfig
---@field question? VantageCommandConfig
---@field edit? VantageCommandConfig
---@field annotate? VantageAnnotateCommandConfig
---@field search? VantageSearchCommandConfig
---@field walkthrough? VantageCommandConfig

---@class VantageAgentContextConfig
---@field enabled? boolean
---@field path? string
---@field max_bytes? integer
---@field max_age_ms? integer

---@class VantageDebugConfig
---@field log_path? string Absolute path to the NDJSON debug log file. nil = disabled.

---@class VantageInputOptions
---@field prompt? string
---@field default? string
---@field completion? string|function
---@field highlight? function
---@field scope? string

---@class VantageInputConfig
---@field provider? "vim.ui.input"|"ui2" Input provider for prompts. ui2 bypasses vim.ui.input overrides and uses the builtin input path.
---@field lens? VantageInputOptions
---@field question? VantageInputOptions
---@field edit? VantageInputOptions
---@field search? VantageInputOptions

---@class VantageOutputActionsConfig
---@field promote? string Keymap to promote float to horizontal split.
---@field promote_vsplit? string Keymap to promote float to vertical split.

---@class VantageOutputConfig
---@field width? number
---@field height? number
---@field border? string|string[]
---@field wrap? boolean
---@field target? "popup"|"buffer"|"buffer_vsplit" Default output destination.
---@field promote_modifiable? boolean Whether promoted/direct buffers are editable.
---@field actions? VantageOutputActionsConfig Keymaps for float promotion.

---@class VantageCompositionKeymapsConfig
---@field send? string|string[] Bound in normal and insert mode.
---@field history_prev? string|string[] Cycle to an older prompt. Default <Up>.
---@field history_next? string|string[] Cycle to a newer prompt. Default <Down>.
---@field close? string|string[] Normal mode only; hides the window, content persists.

---@class VantageCompositionUiConfig
---@field height? number Fraction of editor height for the split.
---@field min_height? integer
---@field max_height? integer
---@field keymaps? VantageCompositionKeymapsConfig

---@class VantageCompositionConfig
---@field on_send? fun(text: string): boolean|nil Destination for staged text. Return false to signal failure, which leaves the content staged. When unset, staged text routes through Vantage's own question flow.
---@field clear_on_send? boolean Empty the buffer after a successful send. Default true.
---@field close_on_send? boolean Close the window after a successful send. Default true.
---@field separator? string Rule inserted between appended entries. Default "---".

---@class VantageMonitorConfig
---@field interval_ms? integer Poll cadence in milliseconds. Default 1000.
---@field limit? integer Recent-change entries kept for cycling. Default 50.
---@field self_write_grace_ms? integer Changes to a path this instance wrote within this window are ignored, so your own `:w` never appears in the feed. Default 2000.
---@field poll_timeout_ms? integer How long an unanswered poll may run before it is killed and a fresh one allowed. Default 30000. A poll already in flight always suppresses the next tick, so this only rescues a poll that will never answer.
---@field warn_cooldown_ms? integer How long before a repeated warning of the same kind is announced again. Default 300000 (5 minutes). Suppresses notification storms without letting recurring degradation go silent forever.
---@field source? fun(root: string): table Change-detection seam. Must return `{ poll = fun(cb) }`, optionally with `first_hunk = fun(path, cb)`. Defaults to the git adapter in monitor_source.lua.
---@field render? fun(context: VantageMonitorRenderContext) Presentation seam. Replaces the built-in "open the file" behavior wholesale -- this is how a diff view stays config-supplied and diff-plugin agnostic.
---@field on_stop? fun() Called when the mode stops. Only needed by a custom `render` that opened something it must close; the built-in renderer has nothing to tear down.

---@class VantageMonitorRenderContext
---@field path string Absolute path to the changed file.
---@field status string Two-character `git status --porcelain` code.
---@field workspace string Workspace root being watched.
---@field line integer? First changed line, nil when unknown or not applicable.
---@field deleted boolean The path no longer exists on disk.

---@class VantageHistoryConfig
---@field enabled? boolean Record and cycle prompt history. Default true.
---@field limit? integer Entries kept. Default 50.
---@field max_entry_bytes? integer Entries larger than this are skipped, never truncated. Default 1 MiB.
---@field path? string NDJSON file. Defaults under stdpath("state") so prompt text never lands in a project repo.

---@class VantagePromptKeymapsConfig
---@field submit? string|string[]
---@field history_prev? string|string[] Cycle to an older prompt. Default <Up>.
---@field history_next? string|string[] Cycle to a newer prompt. Default <Down>.
---@field cancel? string|string[] Normal mode only, so <Esc> still leaves insert mode.
---@field close? string|string[] Normal mode only; second way to abort, defaults to `q`.
---@field toggle_runtime? string|string[]

---@class VantagePromptConfig
---@field keymaps? VantagePromptKeymapsConfig

---@class VantageSessionOutputKeymapsConfig
---@field close? string|string[]
---@field toggle_raw? string|string[]

---@class VantageSessionOutputUiConfig
---@field refresh_ms? integer
---@field keymaps? VantageSessionOutputKeymapsConfig

---@class VantageUiConfig
---@field input? VantageInputConfig
---@field output? VantageOutputConfig
---@field prompt? VantagePromptConfig
---@field composition? VantageCompositionUiConfig
---@field session_output? VantageSessionOutputUiConfig

---@class VantageConfig
---@field backend? VantageBackendConfig Advanced backend transport settings.
---@field agent? VantageAgentConfig Agent runtime and model target settings.
---@field completion? VantageCompletionConfig Completion runtime and its Pi options.
---@field commands? VantageCommandsConfig Command behavior and command-specific agent options.
---@field composition? VantageCompositionConfig Staging-buffer behavior, including the send destination.
---@field history? VantageHistoryConfig Prompt history recording and cycling.
---@field monitor? VantageMonitorConfig Monitor-mode change detection and presentation.
---@field ui? VantageUiConfig UI hints passed to Neovim's standard UI APIs.
---@field agent_context? VantageAgentContextConfig
---@field debug? VantageDebugConfig

local function default_config()
	return {
		backend = {
			mode = "stdio",
			command = { "node", plugin_root() .. "/server/out/neovim/stdio-server.js" },
		},
		agent = {
			runtime = "pi",
			models = {
				{
					name = "default",
					provider = "openai",
					model = "gpt-4o-mini",
				},
			},
			default_model = "default",
			options = {},
			session_output = {
				history_limit = 10,
			},
		},
		completion = {
			options = {},
		},
		commands = {
			explain = {
				include_lens = true,
				runtime = "agent",
				options = {},
			},
			question = {
				include_lens = false,
				runtime = "agent",
				options = {},
			},
			edit = {
				include_lens = false,
				runtime = "agent",
				-- Refuse a whole-file completion edit above this many lines. The
				-- request would ship every line into a single call, so past a few
				-- thousand it either errors on context length after a long wait or
				-- truncates -- both worse than being told up front.
				max_file_lines = 2000,
				options = {},
			},
			annotate = {
				include_lens = true,
				runtime = "agent",
				waiting_message_ms = 30000,
				options = {},
			},
			search = {
				include_lens = true,
				options = {},
			},
			walkthrough = {
				include_lens = true,
				options = {},
			},
		},
		composition = {
			on_send = nil,
			clear_on_send = true,
			close_on_send = true,
			separator = "---",
		},
		history = {
			enabled = true,
			limit = 50,
			max_entry_bytes = 1048576,
			-- User-global on purpose: `.vantage/` is git-ignored per artifact in
			-- consumer repos, so a workspace-scoped file would be committable.
			path = vim.fn.stdpath("state") .. "/vantage/prompt-history.ndjson",
		},
		monitor = {
			interval_ms = 1000,
			limit = 50,
			self_write_grace_ms = 2000,
			poll_timeout_ms = 30000,
			warn_cooldown_ms = 300000,
			-- nil = the git adapter / the built-in renderer that opens each
			-- changed file in the current window. Both are seams so consumers can
			-- swap detection or presentation without a fork.
			source = nil,
			render = nil,
			on_stop = nil,
		},
		ui = {
			keybind_hints = true,
			output = {
				width = 0.82,
				height = 0.72,
				border = "rounded",
				wrap = true,
				target = "popup",
				promote_modifiable = false,
				actions = {
					promote = '<leader>"',
					promote_vsplit = "<leader>%",
				},
			},
			composition = {
				height = 0.32,
				min_height = 10,
				max_height = 32,
				keymaps = {
					send = "<C-g>",
					close = "q",
					history_prev = "<Up>",
					history_next = "<Down>",
				},
			},
			prompt = {
				keymaps = {
					submit = "<CR>",
					cancel = "<Esc>",
					close = "q",
					toggle_runtime = "<C-r>",
					history_prev = "<Up>",
					history_next = "<Down>",
				},
			},
			session_output = {
				refresh_ms = 750,
				keymaps = {
					close = "q",
					toggle_raw = "r",
				},
			},
			input = {
				provider = "vim.ui.input",
				lens = {
					prompt = "Vantage lens: ",
				},
				question = {
					prompt = "Vantage question: ",
				},
				edit = {
					prompt = "Vantage edit: ",
				},
				search = {
					prompt = "Vantage search: ",
				},
			},
		},
		agent_context = {
			enabled = true,
			path = ".vantage/agent-context.md",
			max_bytes = 12000,
			max_age_ms = nil,
		},
		debug = {
			log_path = nil,
		},
	}
end

M.config = default_config()

M.lens = nil

---@type VantageModelConfig|nil
M.current_model = nil

---Resolve a model preset by name, falling back to the first model in the list.
---@param name? string
---@return VantageModelConfig|nil
function M.resolve_model(name)
	local models = M.config.agent and M.config.agent.models or {}
	if name then
		for _, m in ipairs(models) do
			if m.name == name then
				return m
			end
		end
		return nil
	end
	-- No name: use default_model, then first in list
	local default_name = M.config.agent and M.config.agent.default_model
	if default_name then
		for _, m in ipairs(models) do
			if m.name == default_name then
				return m
			end
		end
	end
	return models[1]
end

---Switch the active model preset by name. Resets the buddy session.
---@param name string
---@return boolean success
---@return string error_message
---Apply a model preset's options to the shared agent config.
---@param model VantageModelConfig
local function apply_model_options(model)
	M.config.agent.provider = model.provider
	M.config.agent.model = model.model
	if model.apiKey or model.options then
		M.config.agent.options = M.config.agent.options or {}
		if model.apiKey then
			M.config.agent.options.apiKey = model.apiKey
		end
		if model.options then
			M.config.agent.options = vim.tbl_extend("force", M.config.agent.options, model.options)
		end
	end
end

function M.select_model(name)
	local model = M.resolve_model(name)
	if not model then
		return false, "Unknown model: " .. tostring(name)
	end
	M.current_model = model
	apply_model_options(model)
	return true, model.provider .. "/" .. model.model
end

---This command's configured default runtime ("agent" or "completion"),
---before any per-invocation override.
---@param name string command name, e.g. "explain"
---@return "agent"|"completion"
function M.command_runtime(name)
	local commands = M.config.commands or {}
	local command = commands[name] or {}
	return command.runtime or "agent"
end

---Display label for the currently active agent/model, for user-facing notifications.
---@return string
function M.agent_label()
	local backend_cfg = M.config.backend or {}
	if backend_cfg.mode == "development" then
		return "development"
	end

	if M.current_model then
		return M.current_model.provider .. "/" .. M.current_model.model
	end

	return "the model"
end

---@param config? VantageConfig
function M.setup(config)
	M.config = vim.tbl_deep_extend("force", default_config(), config or {})
	-- The composition buffer outlives setup(), so its keymaps and hints must be
	-- re-derived from the new config rather than frozen at creation time.
	pcall(function()
		require("vantage.composition").refresh()
	end)
	-- History's store adapter and loaded ring latch for the process lifetime,
	-- so a second setup() with a different history.path would keep writing to
	-- the old file.
	pcall(function()
		require("vantage.history").reset()
	end)
	if not M.config.debug or not M.config.debug.log_path then
		if vim.g.vantage_debug_log_path then
			M.config.debug = M.config.debug or {}
			M.config.debug.log_path = vim.g.vantage_debug_log_path
		end
	end
	-- Reset current_model so resolve_model picks from the new config
	M.current_model = nil
	M.current_model = M.resolve_model()
	if M.current_model then
		apply_model_options(M.current_model)
	end
end

function M.set_lens(mode, text)
	M.lens = { mode = mode, text = text }
end

function M.get_lens()
	return M.lens
end

function M.clear_lens()
	M.lens = nil
end

return M
