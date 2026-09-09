# vantage.nvim

vantage.nvim is a Neovim-first AI review and learning assistant.

The current architecture is a Lua Neovim plugin plus a local TypeScript backend. The plugin owns commands, floating markdown windows, and virtual annotation blocks. The backend owns request contracts and agent runtime behavior.

## Public API

### Commands

Vantage commands are explicit: model-backed commands only call the backend after a direct command invocation or prompt-buffer submit. For commands that accept a Vim range, visual mode works through Neovim's normal `:'<,'>` range.

Agentic tool access is intentionally narrow. Only edit requests expose Pi `edit` and `write`; other commands use read-only tools or Vantage-owned submit tools.

The session descriptions below default to `agent.runtime = "pi"`. With `agent.runtime = "adjacent"`, **every agent request (including annotations) instead uses a fresh, disposable fork of the running Pi's active conversation**; while Pi is busy, the fork uses its latest completed turn and excludes work still in progress. Tool sets, prompts, and results stay the same. Completion calls remain independent single-turn Pi calls. See [Adjacent Pi](#adjacent-pi) for installation, discovery, and limitations.

| Command | Normal mode | Range / visual mode | Prompt behavior | Agent/session/tools available | Result |
| --- | --- | --- | --- | --- | --- |
| `:VantageSetLens [mode] [text]` | Yes | No | Prompts for lens text when `text` is omitted. | No model call; no agent tools. | Sets the active lens used by later commands. |
| `:VantageClearLens` | Yes | No | None. | No model call; no agent tools. | Clears the active lens. |
| `:VantageExplain [runtime=agent\|completion]` | Yes | Yes: `:10,20VantageExplain`, `:'<,'>VantageExplain` | None; it explains the current line or selected range. Optional `runtime=` overrides `commands.explain.runtime` (default `agent`) for this invocation only. | Agent runtime: singleton buddy session with read-only tools: `read`, `grep`, `find`, `ls`. Completion runtime: single-turn model call, no session, no tools. | Opens a markdown explanation float. |
| `:VantageQuestion [runtime=agent\|completion] [question]` | Yes | Yes: `:10,20VantageQuestion ...`, `:'<,'>VantageQuestion ...` | If `question` is omitted, opens the floating prompt buffer. Optional `runtime=` overrides `commands.question.runtime` (default `agent`) for this invocation only. | Agent runtime: singleton buddy session with read-only tools: `read`, `grep`, `find`, `ls`. Completion runtime: single-turn model call, no session, no tools. | Opens a markdown answer float. |
| `:VantageEdit [instruction]` | Yes | Yes: `:10,20VantageEdit ...`, `:'<,'>VantageEdit ...` | If `instruction` is omitted, opens the floating prompt buffer with a runtime toggle. Accepts `runtime=agent\|completion` (default `agent`, see `commands.edit.runtime`). | Agent runtime: singleton Pi session with read, grep, find, ls, edit, and write tools. Completion runtime: single-turn call, no tools. | Agent: Pi owns the complete workspace edit. Completion: replaces the selection, or applies SEARCH/REPLACE blocks anywhere in the file when there is no selection. |
| `:VantageAnnotate [runtime=agent\|completion] [scope] [max]` | Yes | Yes: `:10,20VantageAnnotate`, `:'<,'>VantageAnnotate` | None. Optional scope is `line`, `visible`, or `buffer`; optional max is a positive integer; optional `runtime=` overrides `commands.annotate.runtime` (default `agent`) for this invocation only. | Agent runtime: transient annotation session with `submit_annotations` only; does not enter buddy-session memory. Completion runtime: single-turn model call parsed from raw JSON text, no tools. | Renders virtual Annotation Blocks above relevant code lines. |
| `:VantageAnnotationClear` | Yes | No | None. | No model call; no agent tools. | Clears Vantage annotations in the current buffer. |
| `:VantageSearch [query]` | Yes | Yes: `:10,20VantageSearch ...`, `:'<,'>VantageSearch ...` | A prompt is required. If `query` is omitted, including for range/visual search, opens the floating prompt buffer. | Uses the singleton buddy session with read-only tools plus `submit_search_results`. Results are curated through Vantage's structured contract; no file mutation tools. | Populates quickfix with final curated search locations. |
| `:VantageGenerateWalkthrough [prompt]` | Yes | Yes: `:10,20VantageGenerateWalkthrough ...`, `:'<,'>VantageGenerateWalkthrough ...` | A prompt is required. If `prompt` is omitted, opens the floating prompt buffer. | Uses the singleton buddy session with read-only tools plus `submit_walkthrough`. No file mutation tools; Vantage writes the validated pointers to `.vantage/walkthrough.json` itself. | Writes `.vantage/walkthrough.json` and immediately runs `:VantageLoadWalkthrough`. |
| `:VantageStatus` | Yes | No | None. | No model call; no agent tools. Reads local Vantage status only. | Opens the combined Agent Session, Agent Context, and Request status float (whichever of explain/question/edit/annotate is currently tracked). |
| `:VantageSessionOutput` | Yes | No | None. | No model call; no agent tools. Polls Vantage's in-memory session-output history. | Opens a live-updating session activity float; `r` toggles raw details and `q` closes. |
| `:VantageCancel` | Yes | No | None. | No new model call; cancels whatever request is currently tracked (explain/question/edit/annotate, whichever runtime served it) and interrupts the persistent agent session. | Cancels the current tracked request, if any, and the active agentic session, if any. |
| `:VantageAgentReset` | Yes | No | None. | No model call; no agent tools. Clears Vantage-owned in-memory state. | Clears the singleton in-memory buddy session and session-output history. |
| `:VantageCompose` | Yes | No | None. | No model call; no agent tools. | Toggles the composition buffer, a persistent markdown split you stage entries into: opens and focuses it when hidden, hides it when visible. Nothing else shows it — appending stages silently. |
| `:VantageComposeSend` | Yes | No | None. | Depends on `composition.on_send`: routes staged text wherever you configure. Unconfigured, it goes through the same path as `:VantageQuestion`. | Sends the staged composition, then clears/closes it per config. A failed send leaves the content staged. |
| `:VantageComposeClear` | Yes | No | None. | No model call; no agent tools. | Empties the composition buffer without destroying it. |
| `:VantageHistory` | Yes | No | Selects a past prompt via `vim.ui.select`. | No model call; no agent tools. | Replaces a prompt/composition buffer's content with the chosen entry, or yanks it to the unnamed register when neither is focused. |
| `:VantageHistoryClearWorkspace` | Yes | No | None. | No model call; no agent tools. | Removes this workspace's history entries. |
| `:VantageMonitor` | Yes | No | None. | No model call; no agent tools. | Toggles monitor mode: a live feed of workspace edits made outside this Neovim. Opens each changed file in the current window; off by default. |
| `:VantageHistoryClearAll` | Yes | No | None. | No model call; no agent tools. | Removes every history entry, across all workspaces. |
| `:VantageHealth` | Yes | No | None. | No model call; no agent tools. Checks local plugin/backend state only. | Alias for `:checkhealth vantage`; reports backend, model target, Pi auth, and Agent Context File health. |

Prompt buffers are markdown scratch floats. Submit with `<CR>` (in either insert or normal mode) by default; configure these under `ui.prompt.keymaps`. Cancel/close keys bind in **normal mode only**, so `<Esc>` keeps its usual job of leaving insert mode: press `<Esc>` to reach normal mode, then `<Esc>` again (or `q`) to abort. Since `<CR>` submits immediately rather than inserting a newline, use `<C-v><CR>` to insert a literal newline when composing a multi-line prompt. When `ui.keybind_hints` is on (the default), every prompt buffer's border footer shows its active keymaps, e.g. `submit <CR>` for Edit/Search/Walkthrough. For commands that accept a `runtime` option (currently Question), the footer also shows an `[x] agent`/`[ ] agent` checkbox, toggled with `<C-r>` (`ui.prompt.keymaps.toggle_runtime`) while the buffer is focused; the runtime in effect when you submit is the one used for that request. With `ui.keybind_hints = false`, only the checkbox's checked state still shows (without the key); plain action hints like `submit` disappear entirely.

### Lua API

All public Lua functions are available from `require("vantage")` and share the same implementation paths as user commands.

| Lua function | Equivalent command / behavior | Agent/session/tools available |
| --- | --- | --- |
| `setup(config)` | Configure Vantage and register commands. `agent.runtime = "pi"` owns a buddy session; `"adjacent"` forks a running Pi per request, using its latest completed turn when busy. `"adjacent-or-pi"` detects adjacent Pi once on the first agent-runtime backend command, otherwise uses Pi, and keeps the choice until backend restart. Optional `agent.adjacent.socket_path` selects a specific Pi bridge. | No model call; no agent tools. |
| `set_lens(mode, text)` | `:VantageSetLens {mode} {text}`. | No model call; no agent tools. |
| `get_lens()` | Return the current lens table or `nil`. | No model call; no agent tools. |
| `clear_lens()` | `:VantageClearLens`. | No model call; no agent tools. |
| `prompt_lens(mode)` | Prompt for lens text, then set the lens. | No model call; no agent tools. |
| `explain(opts)` | `:VantageExplain`; accepts command-style `opts` including `range`, `line1`, `line2`, and `runtime` (`"agent"` \| `"completion"`, overrides `commands.explain.runtime`). `opts.callback(err, result)` skips the markdown float and receives `result.markdown` directly. | Agent runtime: singleton buddy session; `read`, `grep`, `find`, `ls`. Completion runtime: single-turn model call, no tools. |
| `question(opts)` | `:VantageQuestion`; `opts.args` is the inline question when present. `opts.runtime` overrides `commands.question.runtime` and seeds the prompt buffer's agent/completion checkbox (toggled with `<C-r>`; the checkbox's state at submit time wins). `opts.callback(err, result)` skips the markdown float and receives `result.markdown` directly. | Agent runtime: singleton buddy session; `read`, `grep`, `find`, `ls`. Completion runtime: single-turn model call, no tools. |
| `edit(opts)` | `:VantageEdit`; `opts.args` is the inline edit instruction when present. `opts.runtime` seeds the prompt buffer's agent/completion toggle. | Agent runtime: singleton buddy session with `read`, `grep`, `find`, `ls`, `edit`, and `write`; Pi owns the complete workspace edit. Completion runtime: single-turn model call, no tools; Vantage applies the returned replacement or SEARCH/REPLACE blocks. |
| `annotate(opts)` | `:VantageAnnotate`; `opts.fargs` carries scope/max arguments. `opts.runtime` overrides `commands.annotate.runtime`. | Agent runtime: transient annotation session; `submit_annotations` only, does not enter buddy memory. Completion runtime: single-turn model call parsed from raw JSON text, no tools. |
| `clear_annotations()` | `:VantageAnnotationClear`. | No model call; no agent tools. |
| `search(opts)` | `:VantageSearch`; `opts.args` is the inline query when present. Missing args open the prompt buffer. | Singleton buddy session; `read`, `grep`, `find`, `ls`, `submit_search_results`. No file mutation tools. |
| `generate_walkthrough(opts)` | `:VantageGenerateWalkthrough`; `opts.args` is the inline prompt when present. Missing args open the prompt buffer. | Singleton buddy session; `read`, `grep`, `find`, `ls`, `submit_walkthrough`. No file mutation tools; writes `.vantage/walkthrough.json` and loads it. |
| `status()` | `:VantageStatus`. | No model call; no agent tools. |
| `session_output()` | `:VantageSessionOutput`. | No model call; no agent tools; polls in-memory session-output history. |
| `cancel(opts)` | `:VantageCancel`. `opts.callback(err, result)` skips the markdown float and receives `result.markdown` directly. | No new model call; cancels the current tracked request (any runtime) and aborts the active agent session. |
| `agent_reset(opts)` | `:VantageAgentReset`. `opts.callback(err, result)` skips the markdown float and receives `result.markdown` directly. | No model call; clears Vantage's in-memory buddy/output state. In adjacent mode, never resets or modifies the parent Pi conversation. |
| `health()` | `:VantageHealth`; also reachable directly via `:checkhealth vantage`. | No model call; no agent tools. |
| `compose()` | `:VantageCompose`. Toggles visibility; returns `buf, win` with `win` nil when it closed. | No model call; no agent tools. |
| `compose_send()` | `:VantageComposeSend`. Returns `true` when the send succeeded. | Whatever `composition.on_send` targets; the built-in fallback uses the `question` path. |
| `compose_clear()` | `:VantageComposeClear`. | No model call; no agent tools. |
| `compose_append(text, opts)` | Lua-only; no command. Appends an entry, creating the buffer if needed but never showing it — use `compose()` for that. Notifies with the running entry count so staging is not silent. Separation between entries is handled here -- pass `opts.separation = "blank"` for blank-line separation instead of a `---` rule. Returns `false` for nil/blank text. | No model call; no agent tools. |
| `is_composition_buffer(bufnr)` | Lua-only; no command. Whether `bufnr` (default: current) is the composition buffer. Prefer this over reading `b:vantage_composition`. | No model call; no agent tools. |
| `history(opts)` | Lua-only; no command. Recorded prompts, newest first. `opts.workspace` scopes to one root; the default spans all of them. Exposed so integrations can build their own picker. Each entry is `{ kind, text, timestamp, workspaceRoot, filePath?, submitted }` -- these are also the persisted field names, so treat them as a stable contract. `submitted = false` marks a draft captured when a prompt was abandoned rather than sent. | No model call; no agent tools. |
| `history_pick()` | `:VantageHistory`. | No model call; no agent tools. |
| `history_clear_workspace()` | `:VantageHistoryClearWorkspace`. | No model call; no agent tools. |
| `history_clear_all()` | `:VantageHistoryClearAll`. | No model call; no agent tools. |
| `monitor()` | `:VantageMonitor`. Returns whether the mode is active afterwards. | No model call; no agent tools. |
| `monitor_entries()` | Lua-only; no command. Recently changed files, newest first. Each entry is `{ path, status, mtime, at }`, where `status` is the two-character `git status --porcelain` code. Exposed so integrations can build their own picker. | No model call; no agent tools. |
| `prompt(opts)` | Lua-only; no command. Opens the floating prompt buffer to collect multi-line input and hands it to `opts.on_submit(text, runtime)`, without issuing a request of its own. `opts.params` (e.g. from `context(...)`) supplies the `workspaceRoot` used to resolve `@path` / `/skill` references in the submitted text. `opts.runtime` seeds, and `opts.show_runtime_toggle` reveals, the agent/completion checkbox. `opts.title` renders a centered caption on the float's border to label the flow. `on_submit` is not called if the prompt is cancelled. | No model call; no agent tools. |
| `format_reference(spec)` | Lua-only; no command. Formats `{ path, start_line?, end_line? }` as the `@`-reference syntax the prompt buffer parses -- `@path`, `@path line N`, or `@path lines N-M`. An absolute `path` is relativized against the workspace root Vantage resolves refs against, so callers do not need their own path rule. Returns `nil` for a missing/empty path. Line numbers are human- and model-readable annotation; the parser resolves refs at file level. | No model call; no agent tools. |
| `context(opts)` | Lua-only; no command. Returns the context params for the current scope: an explicit command range (`opts.range`/`line1`/`line2`), else a live visual selection, else the cursor line. `params.selectionSource` reports which of `"range"`/`"visual"`/`"cursor"` applied -- the only way to distinguish a real one-line selection from a cursor-line fallback. | No model call; no agent tools. |
| `visual_range()` | Lua-only; no command. The live visual selection's `start_line, end_line`, or `nil` outside visual mode. Prefer this over reading `'<`/`'>`, which hold the *previous* selection when read from a Lua-function keymap. | No model call; no agent tools. |

`require("vantage").CommandNames` exposes the canonical command names for plugin integrations that need to avoid string literals.

### Composing your own prompts

`prompt`, `format_reference`, and `context` are the building blocks for integrations that assemble prompt text themselves — for example a keymap that captures the current selection, collects an instruction, and stages the result somewhere of its own:

```lua
local vantage = require("vantage")
local ctx = vantage.context()

vantage.prompt({
  kind = "memo",
  params = ctx,
  on_submit = function(text)
    local ref = vantage.format_reference({
      path = vim.fn.fnamemodify(ctx.filePath, ":."),
      start_line = ctx.range and ctx.range.startLine,
      end_line = ctx.range and ctx.range.endLine,
    })
    -- assemble and stage `ref .. "\n\n" .. text` however you like, or hand it
    -- straight back to Vantage with vantage.question({ args = text })
  end,
})
```

Vantage deliberately does not own the staging destination, file/git reference pickers, or picker UI — those stay in your own configuration. See `docs/superpowers/specs/2026-08-25-prompt-building-public-api-design.md`.

Because `context(opts)` resolves a live visual selection, keymaps bound to a plain Lua function work correctly in visual mode. That applies to the regular commands too: `vantage.explain({})` from a visual-mode keymap now sends the selection rather than only the cursor line. An explicit `:'<,'>` range always wins over a live selection.

## Installation

vantage.nvim needs Neovim 0.10+, Node.js 22+, and npm. Install from the generated `dist` branch, which contains the Lua plugin and the Node backend source. After your plugin manager clones the repo, run `npm ci --omit=dev && npm run compile` in the plugin directory to install runtime Node dependencies and build the backend. The TypeScript compiler ships as a runtime dependency so this works without dev dependencies.

### lazy.nvim

```lua
{
  "napisani/vantage-nvim",
  name = "vantage.nvim",
  branch = "dist",
  build = "npm ci --omit=dev && npm run compile",
  config = function()
    require("vantage").setup({
      agent = {
        models = {
          { name = "default", provider = "openai", model = "gpt-4o-mini" },
        },
        default_model = "default",
      },
    })
  end,
}
```

### vim-plug

```vim
Plug 'napisani/vantage-nvim', { 'branch': 'dist', 'do': 'npm ci --omit=dev && npm run compile' }
```

Then configure vantage.nvim from your Lua config:

```lua
require("vantage").setup({
  agent = {
    models = {
      { name = "default", provider = "openai", model = "gpt-4o-mini" },
    },
    default_model = "default",
  },
})
```

### Native Packages

```bash
git clone --branch dist https://github.com/napisani/vantage-nvim \
  "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/pack/vantage/start/vantage.nvim"
cd "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/pack/vantage/start/vantage.nvim"
npm ci --omit=dev && npm run compile
```

## Agent Runtime

The backend has separate `AgentRuntime` implementations in `runtime/pi/agent.ts` and `runtime/adjacent/agent.ts`. Each owns its session lifecycle and composes `runtime/pi-agent-common.ts` for prompts, tool restrictions, streaming, result handling, and output history. The runtime factory selects the implementation; the shared logic does not choose a session source. See the [runtime design notes](server/src/neovim/runtime/README.md) and each runtime directory's README for intent, ownership, and guardrails.

### Automatic adjacent-or-pi selection

```lua
require("vantage").setup({
  agent = {
    runtime = "adjacent-or-pi",
    -- agent.models / default_model configure the Pi fallback as usual.
  },
})
```

On the **first agent-runtime command that contacts the backend** (including status or skill lookup), Vantage probes for adjacent Pi without making a model call. Completion-mode commands bypass this probe and continue using the independent Pi completion runtime:

- One matching bridge: use `adjacent` and pin that socket for subsequent fresh forks.
- No bridge: use the owned `pi` runtime with your configured model and auth.
- Multiple matches, permission errors, timeouts, or malformed replies: report the error rather than silently falling back.

The successful choice is cached **once per backend process**, shared by concurrent initial commands. A Pi agent appearing later does not replace the fallback; a selected adjacent Pi disappearing does not trigger fallback. `:VantageAgentReset` clears agent state, not this choice. Restart Neovim or its backend to detect again, including when moving to a different adjacent workspace. Failed or cancelled detection can be retried by the next command.

Only the runtime choice and selected socket are cached; later model/command-option changes still apply. Explicit `"pi"` and `"adjacent"` modes keep their existing behavior, and `"pi"` remains the default. Completion actions still run through the independent Pi completion runtime even when the agent choice is adjacent.

### Adjacent Pi

Requires Pi **0.85+** on macOS or Linux. Load Vantage's extension in the adjacent Pi process, for example:

```bash
pi -e /absolute/path/to/vantage.nvim/server/src/neovim/runtime/adjacent/extension.ts
```

For persistent installation, add the Vantage package directory using `pi install /absolute/path/to/vantage.nvim`, then `/reload` in Pi. If your Pi packages are managed declaratively, add that path to your managed package declarations instead. The package manifest loads only the bridge extension.

In Neovim:

```lua
require("vantage").setup({
  agent = {
    runtime = "adjacent",
    -- Only needed when multiple Pi agents share this workspace:
    -- adjacent = { socket_path = "/tmp/vantage-pi-501/<workspace-hash>-<pid>.sock" },
  },
})
```

The extension displays its socket path at startup. Discovery matches the **canonical workspace directory exactly**; start Pi in Vantage's workspace root. It does not inspect tmux, Herdr, terminal panes, or panel state. In explicit `"adjacent"` mode, no match or multiple matches produces an error, never a silent fallback to a new conversation; `"adjacent-or-pi"` falls back only when its initial probe finds no bridge.

For each agent request, Vantage asks the running Pi for its active branch over an owner-only Unix socket, preserving native messages, branch summaries, and compaction entries. It imports that snapshot into a new in-memory Pi session, prompts it with the existing Vantage command, then disposes it. The next request forks the parent's latest branch, not the previous Vantage response. While the parent is busy, Vantage uses the latest completed turn, including that turn's tool results, without waiting for the entire agent request to finish. Pi keeps one in-memory snapshot, refreshed before a new request and at each `turn_end`; the current partial turn is excluded. A new conversation can fork from its empty starting context. If the extension is loaded mid-turn before it has captured any complete boundary, retry after that turn completes.

- The fork inherits the parent's **model and thinking level**, not the selected Vantage model preset. Completion calls still use Vantage's configured preset.
- Inference and tools execute in the **Vantage backend**, not the adjacent Pi process. Auth resolves through Vantage's normal Pi auth path (`agent.auth.path` if configured); credentials are never transmitted over IPC. Providers available only through a live parent's extension are not inherited.
- Vantage rebuilds its normal workspace instructions and skills. The parent's extension code, custom system-prompt overrides, transient context hooks, and extra tools are **not** cloned. Command-specific tool restrictions remain intact.
- `:VantageCancel` cancels only the Vantage fork, including pending discovery. `:VantageAgentReset` clears only Vantage output/state. Neither touches the parent session. Edits still affect the shared workspace; conversation isolation is not a filesystem sandbox.
- Status identifies adjacent mode; session output records the source session, leaf, and model, and labels snapshots taken from the latest completed turn while the parent is busy, without persisting a parent transcript. The parent snapshot is bounded to 32 MiB; IPC has a five-second deadline.
- The bridge starts only in Pi's interactive TUI, closes on shutdown/reload/session replacement, and is unavailable to other OS users. Other processes running as your user can read it; this is not isolation from same-user applications.

### Owned Pi sessions (default)

Vantage uses Pi through `@earendil-works/pi-coding-agent` as its agent runtime. Models are configured as named presets in `agent.models`. Each preset specifies a Pi provider/model target.

```lua
require("vantage").setup({
  agent = {
    models = {
      {
        name = "fast",
        provider = "openai",
        model = "gpt-4o-mini",
        options = { reasoning = "low" },
      },
      {
        name = "smart",
        provider = "anthropic",
        model = "claude-sonnet-4-20250514",
        options = { reasoning = "high" },
      },
    },
    default_model = "fast",
    -- Optional freeform Pi options for the agent runtime.
    options = {
      reasoning = "high",
    },
  },
  completion = {
    -- Optional freeform Pi options for completion runtime calls.
    options = {
      -- maxTokens = 2048,
    },
  },
})
```

Each model preset supports:
- `name` (required): unique identifier, used with `:VantageModel` to switch.
- `provider` (required): Pi provider name (e.g. `openai`, `anthropic`).
- `model` (required): Pi model name (e.g. `gpt-4o-mini`, `claude-sonnet-4-20250514`).
- `apiKey` (optional): per-model API key override.
- `options` (optional): freeform Pi options that are applied to the selected agent model.

Per-model `apiKey` takes precedence over `agent.options.apiKey`. If neither is set, Vantage tries to resolve Pi OAuth credentials from `agent.auth.path`, `<workspace>/auth.json`, `./auth.json`, `~/.config/pi/auth.json`, then `~/.config/pi-ai/auth.json`. If no Pi OAuth credentials are found, Vantage leaves credentials unset so Pi can still use provider auth such as `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, Google ADC, or AWS credentials.

For subscription-backed providers such as `openai-codex`, log in with Pi once. If Pi writes `auth.json` to the current directory, move it to the default Pi config path:

```bash
npx @earendil-works/pi-ai login openai-codex
mkdir -p ~/.config/pi
mv auth.json ~/.config/pi/auth.json
```

```lua
require("vantage").setup({
  agent = {
    models = {
      {
        name = "codex",
        provider = "openai-codex",
        model = "gpt-5.3-codex",
        options = { reasoning = "medium" },
      },
    },
    default_model = "codex",
  },
})
```

Do not commit Pi OAuth auth files. This repository ignores `auth.json` by default because it can contain refresh tokens.

Vantage Agent Sessions are enabled by default. The backend keeps one in-memory singleton buddy session for the current backend/workspace process. Explain, question, edit, and search share that buddy session. Annotations use transient sessions and do not enter buddy-session memory. Session state is not persisted across Neovim/backend restarts.

## Configuration Reference

The Lua config is documented with `---@class` annotations in `lua/vantage/state.lua` so Lua language servers can complete fields from `VantageConfig`.

```lua
---@type VantageConfig
require("vantage").setup({
  agent = {
    models = {
      {
        name = "default",
        provider = "openai",
        model = "gpt-4o-mini",
      },
    },
    default_model = "default",
    auth = {
      path = vim.fn.expand("~/.config/pi/auth.json"),
    },
    options = {
      -- Freeform Pi options for the agent runtime. Vantage adds no
      -- temperature, token, timeout, or other model-option defaults.
      reasoning = "medium",
      -- apiKey = "sk-...",
    },
    session_output = {
      history_limit = 10,
    },
  },
  completion = {
    options = {
      -- Freeform Pi options for one-shot completion calls.
      -- temperature = 0.1,
    },
  },
  commands = {
    explain = {
      runtime = "agent", -- or "completion"; overridable per-invocation with runtime=
      options = {},
    },
    question = {
      runtime = "agent",
      options = {},
    },
    edit = {
      -- no runtime field: edit is always agent-only
      options = {},
    },
    annotate = {
      runtime = "agent",
      waiting_message_ms = 30000,
      options = {},
    },
  },
  history = {
    enabled = true,
    limit = 50,
    max_entry_bytes = 1048576,   -- larger entries are skipped, never truncated
    -- default: stdpath("state").."/vantage/prompt-history.ndjson"
    path = nil,
  },
  composition = {
    on_send = nil,          -- fun(text): boolean|nil; nil routes through `question`
                            -- must be a function if set; a non-function is refused
    clear_on_send = true,
    close_on_send = true,
    separator = "---",
  },
  ui = {
    keybind_hints = true,
    output = {
      width = 0.82,
      height = 0.72,
      border = "rounded",
      wrap = true,
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
      },
    },
    prompt = {
      keymaps = {
        submit = "<CR>",
        cancel = "<Esc>",
        close = "q",
        toggle_runtime = "<C-r>",
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
    },
  },
  agent_context = {
    enabled = true,
    path = ".vantage/agent-context.md",
    max_bytes = 12000,
    max_age_ms = nil,
  },
})
```

Config groups:

- `agent.models`: list of named model presets. Each entry has `name`, `provider`, `model`, optional `apiKey`, and optional `options`.
- `agent.default_model`: name of the model preset to use on startup.
- `agent.auth.path`: optional Pi OAuth `auth.json` path. If omitted, Vantage checks `<workspace>/auth.json`, `./auth.json`, `~/.config/pi/auth.json`, then `~/.config/pi-ai/auth.json`.
- `agent.session_output.history_limit`: backend-owned retention for `:VantageSessionOutput` activity entries.
- `agent.options`: optional freeform Pi options for the agent runtime. Vantage does not add model-option defaults.
- `completion.options`: optional freeform Pi options for one-shot completion runtime calls. These are independent from `agent.options` and are passed to Pi as supplied.
- `commands.*.runtime` (default `"agent"`): which runtime a command uses when no `runtime=` token is given. Honored by `explain`, `question`, `annotate`, and `edit`.
- `commands.edit.max_file_lines` (default `2000`): refuse a whole-file completion edit above this many lines, rather than shipping every line into one call and failing on context length or truncating. Select a range or use `runtime=agent` instead.
- `commands.annotate.waiting_message_ms`: when to show a still-waiting annotation notification.
- `commands.*.options`: command-specific freeform Pi options layered over `agent.options` for agent-runtime commands.
- `ui.keybind_hints` (default `true`): shows each output surface's active keymaps as a keybind hint -- a floating-window footer for the output popup and Question's prompt buffer, or a window-local statusline for split/vsplit output buffers (regular windows don't support footers). Examples: `[x] agent <C-r>  submit <CR>` on the Question and Edit prompt buffers, `close q  promote <leader>"  vsplit <leader>%` on the output popup, `close q` on a promoted or direct-target output buffer, and `[ ] raw r  close q` on `:VantageSessionOutput`. Set to `false` to hide the keybind text; checkbox-style hints (like the agent/completion toggle) still show their checked state without the key.
- `ui.output.actions`: keymaps bound to the output popup buffer -- `promote` (default `<leader>"`) and `promote_vsplit` (default `<leader>%`) move the popup's content into a regular horizontal/vertical split buffer. They're only bound on the popup itself -- a buffer already produced by promotion, or by `ui.output.target: "buffer"/"buffer_vsplit"`, only keeps `close`, since it's already a plain split.
- `history`: prompt-history recording and cycling. `enabled` (default `true`) turns the whole feature off — no recording, no reading, and the cycle keymaps are not bound, so `<Up>`/`<Down>` keep moving the cursor; `limit` (default `50`) caps retained entries; `max_entry_bytes` (default 1 MiB) skips anything larger rather than truncating it, so a stored entry is always byte-exact; `path` defaults under `stdpath("state")` — deliberately *not* in the workspace, since `.vantage/` is git-ignored per artifact and a project-local file would be committable.
- `monitor`: monitor-mode behavior. `interval_ms` (default `1000`) is the poll cadence; `limit` (default `50`) caps the recent-change ring you cycle through; `self_write_grace_ms` (default `2000`) is how long a path this instance wrote is ignored, so your own `:w` never appears in the feed; `poll_timeout_ms` (default `30000`) is how long an unanswered poll may run before it is killed and a fresh one allowed — a poll already in flight, or a render still walking its queue, always suppresses the next tick, so this only rescues a poll that will *never* answer; `warn_cooldown_ms` (default `300000`) is how long before a repeated warning of the same kind is announced again, so recurring degradation cannot go silent forever. `source` replaces change detection — any `fun(root)` returning `{ poll = fun(cb) }`, optionally with `first_hunk = fun(path, cb)` — and `render` replaces the presentation wholesale, receiving a single context table (see Monitor Mode below). `on_stop` is only needed by a custom `render` that opened something it must close. All three default to `nil`, meaning the built-in git adapter and the built-in "open the file" behavior.
- `composition`: staging-buffer behavior. `on_send` is the send destination (see Composition below); `clear_on_send` / `close_on_send` (both default `true`) control what happens after a successful send; `separator` (default `"---"`) is the rule text inserted between appended entries -- distinct from `compose_append`'s `opts.separation`, which selects the *style* (`"rule"` or `"blank"`). A non-function `on_send` is refused rather than silently falling back to the model, and the unconfigured fallback attributes the request to the buffer you were working in, clearing only once it responds.
- `ui.composition`: the composition split's `height` (fraction of editor height), `min_height`, `max_height`, and `keymaps` (`send` default `<C-g>`, bound in normal and insert; `close` default `q`, normal only).
- `ui.output`: readable markdown float defaults for Vantage output.
- `ui.prompt.keymaps`: floating prompt-buffer mappings for missing Question/Edit/Search prompts. `submit` (default `<CR>`) and `toggle_runtime` (default `<C-r>`, for the agent/completion checkbox on runtime-eligible prompts -- currently Question) bind in both insert and normal mode. `cancel` (default `<Esc>`) and `close` (default `q`) bind in **normal mode only**, deliberately: binding an `<Esc>` default in insert mode would close the float instead of leaving insert mode, making normal mode unreachable.
- `ui.session_output.refresh_ms` and `ui.session_output.keymaps`: live transcript polling and `q`/`r` keymaps.
- `ui.input.provider`: prompt provider for lens prompts. Question/Edit/Search use the floating prompt buffer when command text is omitted.
- `ui.input.lens`: option table passed to the selected input provider, such as `prompt`, `default`, `completion`, `highlight`, and `scope`.
- `agent_context`: workspace task snapshot settings.

The active lens and command scope take precedence over Agent Task Context. Agent and completion runtimes have independent option bags; command-specific agent options layer over `agent.options`.

### Prompt Buffer Completion

Prompt buffers work without autocomplete. Vantage does not install a completion engine. To opt in, configure your completion plugin explicitly:

```lua
-- nvim-cmp: registers a /skill source named "vantage_skills".
require("vantage.integrations.cmp").setup()
```

```lua
-- blink.cmp: use this provider in your blink sources.providers config.
local ok, provider = require("vantage.integrations.blink").setup()
```

`@file` completion should use your completion plugin's existing path/file source. `/skill` completion uses Pi-owned skill discovery through the Vantage backend. Prompt references append normalized metadata only; Vantage does not inline file or skill contents.

## Composition

The composition buffer is a persistent staging area: you accumulate references,
selections, and instructions into it across many actions, edit it freely as
markdown, then send the whole thing once.

It is deliberately distinct from the prompt buffer:

| | Prompt buffer | Composition |
| --- | --- | --- |
| Surface | ephemeral float | persistent bottom split |
| Lifetime | one prompt, then gone | lives until you send or clear it |
| Purpose | collect a single prompt | accumulate many entries |

```vim
:VantageCompose         " toggle it open/closed
:VantageComposeSend     " send everything staged
:VantageComposeClear    " throw away what's staged
```

`:VantageCompose` is the only thing that both shows and hides the buffer — appending
stages silently and notifies with a running entry count, so a split does not appear
every time you add something. Inside the buffer, `<C-g>` sends and `q` closes the window. Closing only hides
it — staged content persists, so an accidental `:close` costs nothing. Both keys
are configurable under `ui.composition.keymaps`.

### Where staged text goes

`composition.on_send` receives the staged text and returns whether it succeeded.
Returning `false` leaves the content staged, so a failed send never loses work.

```lua
require("vantage").setup({
  composition = {
    on_send = function(text)
      -- route anywhere: a terminal pane, an HTTP call, the system clipboard
      return require("my.agent").send(text)
    end,
  },
})
```

With no `on_send` configured, staged text is sent through the same path as
`:VantageQuestion`, so the feature is useful without any setup.

### Building entries

`compose_append` handles separation, so callers don't hand-roll it:

```lua
local vantage = require("vantage")
local ctx = vantage.context()

vantage.compose_append(vantage.format_reference({
  path = ctx.filePath,          -- absolute is fine; Vantage relativizes it
  start_line = ctx.range and ctx.range.startLine,
  end_line = ctx.range and ctx.range.endLine,
}), { separation = "blank" })

vantage.compose_append("Instruction:\nrename this for clarity")
```

### Scoping integrations to the buffer

Vantage sets `b:vantage_composition` on the buffer, but integrations should use
the predicate rather than the variable:

```lua
-- e.g. enabling a completion source only inside the composition buffer
enabled = function()
  return require("vantage").is_composition_buffer()
end
```

Vantage does not own reference pickers — deciding *which* files to stage stays
in your configuration. See
`docs/superpowers/specs/2026-08-25-composition-buffer-design.md`.

Git plumbing is narrowly scoped rather than absent: monitor mode runs
`git status` and `git diff`, both confined to `monitor_source.lua` and both
replaceable via `monitor.source`. Nothing else in Vantage shells out to git, and
reference sources remain config-side.

## Prompt History

Every prompt you submit is recorded — from the prompt buffer, from an inline
command argument (`:VantageQuestion why is this slow`), or from a composition
send. Cycle them in place with `<Up>` and `<Down>`:

```vim
:VantageHistory                  " pick from this workspace's history
:VantageHistoryClearWorkspace    " purge this workspace
:VantageHistoryClearAll          " purge everything
```

**Arrow keys cycle on every line**, in both the prompt buffer and the
composition buffer. That is a deliberate trade for consistency: those two buffers
lose `<Up>`/`<Down>` cursor movement, so use `j`/`k` to move within a multi-line
prompt. Rebind under `ui.prompt.keymaps` / `ui.composition.keymaps`
(`history_prev`, `history_next`), or set `history.enabled = false` to drop the
keymaps entirely. blink.cmp's own arrow mappings include `fallback`, so its
completion menu still wins while open.

Cycling never loses what you were typing: the buffer's content when you started
cycling is held as a draft and restored when you cycle back past the newest
entry. In the composition buffer, recall replaces the **whole** buffer — the
staged work is recoverable by cycling back, but submitting a recalled entry
discards it, so treat that as the one sharp edge.

### What is recorded

- The **raw text you typed**, never the reference-expanded version — so a
  recalled prompt keeps its `@file` mentions intact and re-expands against
  whatever workspace you are in now.
- Abandoned prompt-buffer text, when you close the float without submitting.
  Those entries cycle normally (that is the point — rescuing a mis-closed
  prompt) and are marked `~` in `:VantageHistory`, so "what did I actually send"
  stays answerable.
- Cycling only offers entries from the current workspace; `history()` returns
  every workspace.

### Where it lives

Each row carries a schema version, so a later field change can migrate old rows rather than silently reading them as absent. The file is created `0600` in a `0700` directory -- prompt text should not be world-readable. Rewrites (compaction and the clear commands) stage through a temp file and rename, so a failed write cannot truncate your history, and a clear filters what is actually on disk rather than this session's capped view.

An append-only NDJSON file, by default
`stdpath("state").."/vantage/prompt-history.ndjson"` — user-global, deliberately
outside any project, since prompt text should not be committable. Append-only so
several Neovim instances interleave instead of overwriting each other; the file
is compacted on load once it grows well past `history.limit`.

Prompt text sits unencrypted at rest there, which is why the clear commands
exist. A corrupt line is skipped rather than fatal, and a failed write never
breaks a submit — history is a convenience, and is built to fail quietly.

## Monitor Mode

A live review feed for edits made to your workspace by something *other* than
this Neovim — in practice, an agent running in an adjacent pane.

```vim
:VantageMonitor        " toggle the mode on and off
```

While active, Vantage polls `git status --porcelain` on a timer and opens each
changed file in the current window, cursor on its first changed hunk. New files,
deletions, and gitignore filtering all come free, because git already computes
them.

**Monitor mode binds no keys.** Opening a file is already a Vim jump, so each
change lands in the jumplist and `<C-o>` / `<C-i>` walk the trail of recent
edits with nothing of Vantage's involved:

```
        agent edits three files
        ────────────────────────────────▶
        a.lua        b.lua        c.lua       ← you end here
          ▲            ▲            │
          └── <C-o> ───┴── <C-o> ───┘
                  <C-i> walks forward again
```

A burst renders every change in order, oldest first, so the trail matches the
order the files actually changed in.

Three behaviors are worth knowing, because each defends against a specific way
this could go wrong:

**Your own writes are ignored.** A `BufWritePost` in this instance suppresses
that path for `monitor.self_write_grace_ms`, so saving a file does not replay it
back at you as though the agent had written it.

**Nothing moves while you are typing.** The renderer acts only in normal mode.
Swapping the buffer out from under someone mid-insert would send their next
keystrokes into the file the agent is editing. The change still enters the ring,
so `monitor_entries()` and anything built on it still sees it.

**A modified buffer is never reloaded.** If a changed file has unsaved work,
Vantage reports that it changed on disk rather than discarding your edits.

### Replacing the presentation

`monitor.render` replaces the built-in behavior wholesale and receives one
context table, which is how a diff view stays yours to configure — Vantage never
names a diff plugin:

```lua
monitor = {
  render = function(context)
    -- context.path      absolute path to the changed file
    -- context.status    two-character git porcelain code
    -- context.workspace workspace root being watched
    -- context.line      first changed line, or nil
    -- context.deleted   true when the path is gone
    vim.cmd("DiffviewOpen -- " .. vim.fn.fnameescape(context.path))
  end,
  on_stop = function()
    vim.cmd("DiffviewClose")
  end,
}
```

A single table rather than positional arguments, so the contract can gain fields
without breaking renderers that already exist. `monitor.source` is the matching
seam on the detection side.

## Agent Task Context

Vantage can use task context produced by an adjacent coding agent such as Codex, Claude Code, opencode, or Pi. The integration is artifact-first: the adjacent agent writes a compact Markdown snapshot at `.vantage/agent-context.md`, and Vantage reads it when present. If the file is absent, Vantage commands work normally without the extra context.

The context file is workspace/session state and should not be committed. This repository ignores `.vantage/agent-context.md` by default.

### Configure Adjacent Agents

Vantage reads `.vantage/agent-context.md`, but it does not create or continuously maintain that file. To avoid an always-on system-prompt tax in adjacent agents, use the on-demand `vantage-distill-session` skill when you want to refresh the context snapshot.

Install or copy the skill from this repository:

```text
skills/vantage-distill-session/SKILL.md
```

Then invoke it from the adjacent agent of your choice when useful:

```text
/skill:vantage-distill-session
```

The skill rewrites `.vantage/agent-context.md` as a concise snapshot of the current adjacent-agent session. It does not append logs, raw transcript, or file contents.

Keep the generated artifact local. For a personal-only setup, add it to `.git/info/exclude` in each workspace:

```gitignore
.vantage/agent-context.md
```

For a team setup, commit that ignore rule to `.gitignore`.

Use `:VantageStatus` to see whether Vantage found, included, skipped, or truncated the context file for the current workspace. Then use normal commands such as `:VantageExplain`, `:VantageQuestion`, `:VantageEdit`, and `:VantageAnnotate visible`; Vantage includes the snapshot automatically when it is available.

Vantage includes the current Agent Context File content in explicit command prompts when available. The active lens still has higher precedence than the adjacent-agent context.

See `docs/agent-context.md` for the full artifact convention and design notes. Tool-specific instruction docs are available from Codex, Claude Code, and opencode:

- Codex: <https://developers.openai.com/codex/guides/agents-md>
- Claude Code: <https://docs.anthropic.com/en/docs/claude-code/memory>
- opencode: <https://dev.opencode.ai/docs/rules/>

## Agent Walkthroughs

When the adjacent agent has built up context about specific lines worth reviewing, it can hand Vantage a guided walkthrough instead of a prose summary. The agent writes a structured artifact at `.vantage/walkthrough.json` containing code pointers (file + line) and a short annotation for each.

Author it on demand from the adjacent agent with the bundled skill:

```text
/skill:vantage-author-walkthrough
```

Then, in Neovim, load it:

```text
:VantageLoadWalkthrough
```

This opens a quickfix list with one entry per pointer. Navigating to any pointer renders the agent's annotation inline above the target line (reusing the same display and namespace as `:VantageAnnotate`). Pointers whose recorded line text no longer matches the buffer are prefixed with `[stale]`, since the adjacent agent may have edited the code after writing the walkthrough. Clear everything with `:VantageAnnotationClear`.

The artifact is workspace/session state and is ignored by default (`.vantage/walkthrough.json`). The skill writes JSON with this shape:

```json
{
  "version": 1,
  "pointers": [
    {
      "file": "lua/vantage/state.lua",
      "line": 111,
      "anchor": "command = { \"node\", plugin_root() .. \"/server/out/neovim/stdio-server.js\" },",
      "description": "Backend command is resolved relative to the plugin root, not the editor cwd."
    }
  ]
}
```

### Generating a Walkthrough from Vantage Itself

`:VantageGenerateWalkthrough [prompt]` skips the adjacent agent entirely: it sends your prompt to Vantage's own Pi buddy session, which reads the workspace and returns curated pointers through `submit_walkthrough` (the same structured-submission pattern `:VantageSearch` uses — no raw file-write tool access). Vantage writes the validated result to `.vantage/walkthrough.json` and immediately runs `:VantageLoadWalkthrough` so the quickfix list and inline annotations appear without a separate step.

```text
:VantageGenerateWalkthrough explain how the report total is computed
```

If `prompt` is omitted, the floating prompt buffer opens for input. Configure model options for this command under `commands.walkthrough`, the same shape as `commands.search`.

## Development

Install mise-managed Node.js and project dependencies:

```bash
mise install
mise exec -- npm install
```

Run the full local test suite:

```bash
make test
```

Run backend tests only:

```bash
npm run test:backend
```

Run headless Neovim tests only:

```bash
npm run test:nvim
```

### Lua test layout

The Lua suite is one module per subject under `nvim/tests/spec/`, each registering
its tests into a shared harness at require time:

```
nvim/tests/
  vantage_spec.lua        entry point -- requires every spec module, then runs
  support/
    harness.lua           the test registry and runner
    helpers.lua           shared fixtures (buffers, temp workspaces, capture/stub helpers)
  spec/
    explain_spec.lua      one file per command or module
    annotation_spec.lua   ...
```

Adding a test to an existing subject means touching only that subject's file.
Adding a new subject means creating `spec/<name>_spec.lua` and adding `"<name>"`
to the `SPECS` list in `vantage_spec.lua`. A spec module starts with:

```lua
local test = require("support.harness").test
local helpers = require("support.helpers")
local eq = helpers.eq
```

While iterating, run a single subject instead of the whole suite:

```bash
nvim --headless -u nvim/tests/minimal_init.lua \
  -c "lua require('spec.explain_spec'); require('support.harness').run()" -c qa
```

The `e2e_*_spec.lua` and `dev_init_spec.lua` files are separate entry points with
their own `make` targets and do not go through this harness.

Run the annotation e2e test through the bundled stdio backend with the deterministic development agent runtime:

```bash
make e2e-annotations
```

This writes `.nvim-dev/e2e/annotations.json` with the extmarks Neovim rendered.

Run the local-only, paid real-model command tour:

```bash
make e2e-model
```

`make e2e-model` copies `examples/e2e-codebase` into a fresh disposable
`.nvim-dev/e2e/workspace`, then exercises every public Vantage command in one
headless Neovim session using `openai-codex/gpt-5.6-luna` with low reasoning.
It covers both agent and completion variants where supported, writes
`.nvim-dev/e2e/model-all-commands.json`, and is deliberately excluded from
normal tests and CI because it requires live credentials and costs money. The
provider, model, and reasoning level are fixed for this regression check;
`E2E_WAIT_MS`, `PI_TIMEOUT_MS`, and `PI_ANNOTATION_TIMEOUT_MS` remain available
when a slower run needs more time.

## Manual Neovim Smoke Test

Compile the backend:

```bash
npm run compile
```

Open Neovim with only the repo-local development config:

```bash
make run
```

The repo-local development config uses the internal development agent runtime by default so command plumbing is visible without starting a model request.

Open Neovim with the Pi agent runtime:

```bash
make run-pi
```

`make run-pi` defaults to `openai/gpt-4o-mini`, a five-minute general request timeout, and a five-minute annotation timeout. Override them when needed:

```bash
make run-pi PI_PROVIDER=openai PI_MODEL=gpt-4o-mini PI_ANNOTATION_TIMEOUT_MS=45000
```

Manual Pi runs write `.nvim-dev/trace/pi-prompt.txt` when a request starts and `.nvim-dev/trace/pi-response.txt` when Pi returns.

Open a specific file:

```bash
make run FILE=path/to/file.lua
```

Then run:

```vim
:VantageSetLens learning
:VantageExplain
:VantageQuestion
:VantageEdit simplify this line
:VantageAnnotate
:VantageAnnotationClear
:VantageStatus
:VantageSessionOutput
:VantageSearch find related code paths
:VantageCancel
:VantageAgentReset
```

`:VantageExplain` asks the active runtime to explain the current line. It also accepts Vim line ranges and an optional `runtime=agent|completion` override (default `agent`, see `commands.explain.runtime`):

```vim
:10,20VantageExplain
:'<,'>VantageExplain
:VantageExplain runtime=completion
```

`:VantageSetLens [mode] [lens]` sets the active lens. If the lens text is omitted, Vantage prompts with the configured input provider. Without a mode, it reuses the current lens mode or falls back to `general`. Configure prompt metadata with `ui.input.lens`; set `ui.input.provider = "ui2"` to force UI2-backed command-line input.

```vim
:VantageSetLens learning
:VantageSetLens review Check naming clarity
```

`:VantageQuestion [question]` asks a specific question about the current line. If the question is omitted, Vantage opens a floating multi-line prompt buffer; submit with `<CR>`, or press `<Esc>` for normal mode and then `<Esc>`/`q` to abort. The buffer shows an `[x] agent`/`[ ] agent` checkbox in its border, toggled with `<C-r>`, so you can flip the runtime while composing the question instead of only via the `runtime=` token. It also accepts Vim line ranges and an optional `runtime=agent|completion` override (default `agent`, see `commands.question.runtime`) that sets the checkbox's starting state:

```vim
:VantageQuestion
:VantageQuestion why is this value immutable?
:10,20VantageQuestion
:10,20VantageQuestion what is the data flow here?
:'<,'>VantageQuestion what should I notice in this selection?
```

`:VantageEdit [instruction]` applies an edit to the current buffer. **The runtime decides how it works**, because the two runtimes have genuinely different capabilities:

| Runtime | Scope | Model returns |
|---|---|---|
| `agent` (default) | Pi decides from the instruction, using the selection/current line as context | Pi applies the complete edit directly with its native tools |
| `completion` + selection | exactly that range | the complete replacement text for it |
| `completion`, no selection | anywhere in the file | SEARCH/REPLACE blocks |

**Agent mode delegates the whole edit to Pi.** It has native `edit` and `write` tools in addition to its read/search tools, so it can inspect the workspace and make every change required by the instruction. Vantage does not apply agent output or wait for `submit_edit`; it only reports completion and asks Neovim to notice external file changes.

**Completion mode is a single call with no tools**, which is the entire reason the block format exists. With a selection the destination is already chosen, so replacement text suffices. Without one, the model has to say where each change goes:

````
lua/vantage/monitor.lua
```lua
<<<<<<< SEARCH
local interval = config().interval_ms or 1000
=======
local interval = config().interval_ms or 500
>>>>>>> REPLACE
```
````

This is aider's format, chosen because it is what the ecosystem standardized on — models have the most training exposure to it, and it carries no line numbers to get wrong. A block naming a different file is dropped before it reaches the buffer: completion mode only ever writes the current file. Multi-file work belongs to agent mode, where Pi owns the workspace edit. A block with no filename header is kept, since the header is optional.

Blocks are a completion-mode concept only. Asking the agent for a one-shot anchored format would throw away the investigation it can actually do.

Blocks are matched against the live buffer, tolerant of trailing-whitespace and indentation differences but **strict about content** — a block whose text does not match, or that matches in several places, is skipped and reported rather than guessed at. Everything that did match applies as **one undo step**, so a single `u` reverts the whole edit, and the notification says how many blocks applied and how many were skipped. A response with no blocks at all is a successful no-op, since the prompt invites exactly that when no edit is needed.

If the instruction is omitted, Vantage opens a floating multi-line prompt buffer; submit with `<CR>`, or press `<Esc>` for normal mode and then `<Esc>`/`q` to abort. The prompt buffer carries the same `[x] agent <C-r>` runtime toggle as Question, so you can switch between the full agent and a single completion call per invocation.

```vim
:VantageEdit
:VantageEdit rename value to count
:VantageEdit runtime=completion rename value to count
:10,20VantageEdit simplify this branch
:'<,'>VantageEdit convert this to early returns
```

`:VantageAnnotate` asks the active runtime to add virtual Annotation Blocks above relevant code lines in the current line, visible window, full buffer, or explicit line range. New annotations are additive; an annotation returned for the exact same buffer position replaces the older annotation at that position. Accepts an optional `runtime=agent|completion` override (default `agent`, see `commands.annotate.runtime`) alongside its scope/max arguments, e.g. `:VantageAnnotate runtime=completion buffer`. `:VantageAnnotationClear` removes all vantage.nvim annotations from the current buffer.

`:VantageStatus` opens one status float with Agent Session, Agent Context, and Request sections. It reports the current buddy session state, whether the workspace Agent Context File was included, and whichever of explain/question/edit/annotate is currently (or was most recently) tracked.

`:VantageSessionOutput` opens a live-updating floating transcript of recent Vantage activity. It shows entries chronologically with the latest output at the bottom. Press `r` to toggle raw details and `q` to close.

`:VantageSearch [query]` runs an explicit agentic project search and opens the final curated locations in quickfix. Search always requires an explicit prompt. If the query is omitted, including for ranged or visual search, Vantage opens the same floating prompt buffer used by Question/Edit.

`:VantageCancel` cancels whichever of explain/question/edit/annotate is currently tracked as in flight (regardless of which runtime served it) and also aborts the active agentic session. `:VantageAgentReset` clears the singleton in-memory buddy session. Explain, question, edit, and search share that session; annotations use transient sessions and do not enter buddy memory. For review-style feedback, use `:VantageQuestion review this for correctness and clarity`.

`VantageAnnotate` accepts simple scope and budget arguments:

```vim
:VantageAnnotate
:VantageAnnotate line
:VantageAnnotate visible
:VantageAnnotate visible 10
:VantageAnnotate buffer
:VantageAnnotate buffer 20
```

With no arguments, `VantageAnnotate` annotates only the current line. `line` is an explicit form of the same behavior. `visible` annotates the currently visible buffer lines, and `buffer` annotates the full current buffer. A numeric argument sets the maximum annotation budget for that request.

Without a numeric override, multi-line scopes derive their maximum annotation budget from relevant non-empty, non-comment lines. Visual ranges and `visible` use 25% of relevant lines with a minimum of 1 and maximum of 12. `buffer` uses 15% with a minimum of 3 and maximum of 24. The agent can return fewer Annotation Blocks when fewer lines are noteworthy, and each block can vary in depth based on the active lens.

`VantageAnnotate` also accepts Vim line ranges:

```vim
:10,20VantageAnnotate
:'<,'>VantageAnnotate
:'<,'>VantageAnnotate 5
```
