# Vantage Completed Improvements

> **Path note (2026-08-26):** the Pi/agent runtime modules were reorganized into
> `server/src/neovim/runtime/{pi,development}/`. Entries below name their
> pre-reorg paths (`agent/pi-runtime.ts`, `completion/pi-runtime.ts`,
> `agent/session-store.ts`, …) as they were at the time; the current equivalents
> are `runtime/pi/agent.ts`, `runtime/pi/completion.ts`, and
> `runtime/pi/session-store.ts`.

Items that have been implemented or confirmed as already working. Moved here from `improvement-ideas.md` to keep the backlog focused on what's left.

---

## 1A. Debug-flag session tailing (score: 9) ✅ Implemented

**Completed**: 2026-08-15

**What was built**:
- `debug.log_path` config field in `VantageConfig` (opt-in, nil by default).
- `vim.g.vantage_debug_log_path` fallback for `make run-pi`.
- NDJSON file logging in `backend.lua` transport layer (request + response events).
- `:VantageDebugLog` command opens the log in a scratch buffer with `CursorHold` auto-refresh.
- `make tail-debug` target for live log tailing.
- All file I/O is `pcall`-wrapped (best-effort, never breaks requests).

**Files changed**:
- `lua/vantage/state.lua` — `VantageDebugConfig` class, default config, `vim.g` fallback
- `lua/vantage/backend.lua` — `log_event()`, `write_ndjson()`, callback wrapping
- `lua/vantage/debug_log.lua` *(new)* — scratch buffer viewer
- `lua/vantage/command_names.lua` — `debug_log = "VantageDebugLog"`
- `lua/vantage/commands.lua` — `M.debug_log()`, command registration
- `lua/vantage/init.lua` — `M.debug_log()` public API
- `Makefile` — `VANTAGE_DEBUG_LOG`, `tail-debug` target, `PI_DEV` update

---

## 2A. Per-model reasoning levels (score: 8) ✅ Implemented

**Completed**: 2026-08-15

**What was built**:
- `VantageModelConfig` type: `name`, `provider`, `model`, `apiKey` (optional), `options` (optional per-model overrides).
- `agent.models` list replaces the old flat `agent.provider`/`agent.model` fields.
- `agent.default_model` selects the initial preset.
- `state.resolve_model(name)` resolves by name with fallback to default.
- `state.select_model(name)` switches the active preset, merges per-model options into shared `agent.options`, and syncs `provider`/`model`/`apiKey`.
- `:VantageModel [name]` command: picker without args, direct switch with args.
- `M.model(name)` and `M.select_model(name)` public Lua API.
- Per-model `options` (temperature, maxTokens, timeoutMs, reasoning, etc.) override shared `agent.options`.
- Per-model `apiKey` overrides shared `agent.options.apiKey`.
- Switching models resets the buddy session (Pi sessions are model-bound).

**Files changed**:
- `lua/vantage/state.lua` — `VantageModelConfig` type, `resolve_model()`, `select_model()`, `apply_model_options()`, `current_model` state
- `lua/vantage/command_names.lua` — `model = "VantageModel"`
- `lua/vantage/commands.lua` — `:VantageModel` command with picker and direct switch
- `lua/vantage/init.lua` — `M.model()` and `M.select_model()` public API
- `nvim/dev/init.lua` — maps `vim.g` vars into models list
- `nvim/tests/vantage_spec.lua` — all test setups converted to models format
- `README.md` — config examples updated

---

## 3A. Move agent response to real buffer (score: 9) ✅ Implemented

**Completed**: 2026-08-15

**What was built**:
- `ui.output.target` config: `"popup"` (default float), `"buffer"` (horizontal split), `"buffer_vsplit"` (vertical split).
- When target is `"buffer"` or `"buffer_vsplit"`, `show_markdown()` opens a split directly instead of a float.
- `ui.output.promote_modifiable` config: promoted/direct buffers are read-only by default.
- `ui.output.actions` config: configurable keymaps for yank (`y`), promote (`<leader>vp`), promote vsplit (`<leader>vP`).
- `M.promote_last_float(mode)` promotes the last float to a horizontal or vertical split.
- `:VantageOutputToBuffer [vsplit]` command.
- `M.output_to_buffer(split_mode)` public Lua API.

**Files changed**:
- `lua/vantage/state.lua` — `VantageOutputActionsConfig`, `target`, `promote_modifiable`, `actions` fields
- `lua/vantage/ui.lua` — target-aware `show_markdown()`, `promote_last_float()`, keymaps
- `lua/vantage/command_names.lua` — `output_to_buffer = "VantageOutputToBuffer"`
- `lua/vantage/commands.lua` — `M.output_to_buffer()`, command registration
- `lua/vantage/init.lua` — `M.output_to_buffer()` public API

---

## 4A. Simple completion runtime (score: 8) ✅ Implemented

**Completed**: 2026-08-15

**What was built**:
- `CompletionRuntime` interface: single `complete(request, context)` method returning `CompletionResult { text, model, provider, usage }`.
- `completion/pi-runtime.ts`: `AISDKCompletionRuntime` using Pi's `streamSimple` (single-turn model call, no session, no tools).
- `completion/development-runtime.ts`: `DevelopmentCompletionRuntime` for deterministic test responses.
- `completion/runtime-factory.ts`: `createCompletionRuntimeFromConfig()` picks dev vs. AI SDK runtime.
- `complete` backend protocol method, Zod-validated `CompleteParams`/`CompleteResult`, dispatched through `CompletionRuntime` in `handlers.ts`.
- Lua `:VantageComplete [prompt]` command, `completion.lua` module, and `M.complete(opts)` public API with optional callback.
- Development backend (`development_backend.lua`) handles `complete` for dev mode.
- Tests: completion runtime factory tests (backend) + `VantageComplete` command tests (Lua).

**Files changed**:
- `server/src/neovim/completion/runtime.ts`, `pi-runtime.ts`, `development-runtime.ts`, `runtime-factory.ts`
- `server/src/neovim/protocol/` (params/backend), `handlers.ts`
- `lua/vantage/completion.lua`, `commands.lua`, `command_names.lua`, `init.lua`, `development_backend.lua`
- `README.md` (command + Lua API tables)

---

## 5A. Health check command (score: 6) ✅ Implemented (simplified scope)

**Completed**: 2026-08-19

**What was built**:
- `lua/vantage/health.lua` — `M.check()` implementing the standard `<plugin>.health` module Neovim's `:checkhealth` looks up automatically, so `:checkhealth vantage` works with no extra registration. Four sections: Backend (dev mode note, or `node` on PATH + compiled server script exists), Model target (`state.resolve_model()`), Pi auth (`agent.auth.path` or the default `~/.config/pi/auth.json`, reported as info rather than error since API-key providers don't need it), Agent Context File (reuses the existing `agent_context.snapshot()` used by `:VantageStatus`).
- `:VantageHealth` command and `require("vantage").health()` Lua API, both a thin alias for `vim.cmd("checkhealth vantage")`.
- Tests: direct `vantage.health.check()` assertions against a stubbed `vim.health`, plus a `:VantageHealth` integration test confirming a `checkhealth` buffer opens.

**Deliberately dropped**: the doc's "Completion plugin integrations available (blink.cmp, nvim-cmp)" check — stale, for the same reason [[4A]]'s cmp/blink framing was stale. Vantage's completion is a prompt-driven `:VantageComplete` command with no cmp/blink source to check for.

**Files changed**:
- `lua/vantage/health.lua` *(new)*
- `lua/vantage/command_names.lua`, `commands.lua`, `init.lua`
- `nvim/tests/vantage_spec.lua`
- `README.md`

---

## 2A. More disciplined session management (score: 5) ✅ Implemented (simplified scope)

**Completed**: 2026-08-19

**What was built**: `:VantageStatus`'s agent-session section is enriched with data the singleton session already tracked but didn't surface:
- `SessionRecord` (`session-store.ts`) gained `createdAt`, stamped in `getOrCreate()` when a session is (re)created.
- `SessionStoreStatus` gained `historyLimit`, `sessionTurnCount`, `lastCommandKind`, `lastCommandAt`. `sessionTurnCount`/`lastCommandKind` are computed by filtering `outputHistory` to non-transient entries only — annotation runs are `transient: true` and don't share buddy-session memory, so they're excluded from "session turns"/"last command" to keep the status honest.
- `agentSessionStatus()` (`pi-runtime.ts`) markdown gained "Session age: `<formatAge(...)>`", "Session turns: N", "Last command: `<kind>`", and the existing "Session output entries: N" line now notes the cap (`N (up to <historyLimit> kept)`).
- New `formatAge(ms)` helper (`pi-runtime.ts`) — `Ns` / `NmNs` / `NhNm`.

**Deliberately simplified from the original design**: no `:VantageSessionInfo` (folded into `:VantageStatus` instead, per this item's own alternative), no `User` autocmds for session lifecycle (no existing listener, no precedent for firing them anywhere in the codebase), no `agent.session.auto_reset`/`max_age_ms` config (speculative, no concrete driving need). All of that stays in `improvement-ideas.md` as explicitly deferred.

**Files changed**:
- `server/src/neovim/agent/session-store.ts`
- `server/src/neovim/agent/pi-runtime.ts`
- `server/src/neovim/agent/session-store.test.ts` *(new)*
- `server/src/neovim/agent/runtime-factory.test.ts` — fake `AgentSessionStore.status()` stubs updated for the new required `SessionStoreStatus` fields

---

## 1B. Notification & loading-state polish (score: 5) ✅ Implemented (simplified scope)

**Completed**: 2026-08-19

**What was built**: `model_command.lua`'s model-backed commands now notify a request's lifecycle via plain `vim.notify` calls, gated on the [[3A]] `opts.callback`:
- `explain`, `question`, `agent_cancel`, `reset_agent_session` (via the shared `request_markdown`/`handle_markdown_response` helpers): `"Vantage: requesting from <agent>..."` on start, `"Vantage: done in Xs"` / `"Vantage: request failed after Xs: <reason>"` on completion.
- `edit`, `search`, `generate_walkthrough`: same start notification; their existing completion-detail notifications (`"applied edit replacing N line(s)"`, `"found N result(s)"`, `"generated walkthrough with N pointer(s)"`) now have elapsed time folded in, rather than a separate generic "done" notification.
- When `opts.callback` is present (headless invocation), no notifications fire at all — the caller owns feedback entirely, per [[3A]].
- `state.agent_label()`: new helper resolving `"development"` (dev-mode) or `"<provider>/<model>"` (from `state.current_model`) for use in these messages.

**Deliberately simplified from the original design**: an earlier draft of this item proposed a dedicated `vantage.progress` module with a `waiting_message_ms`-driven "still waiting after Xs" deferred timer, a per-call handle object (`done`/`cancel`), and a new per-command config field — generalizing `annotation_command.lua`'s stateful tracker. That was scrapped as unnecessary complexity for commands that don't commonly hit multi-minute silent waits; the final version is two straight `vim.notify` calls per command with no new module, no timers, and no new config surface. `annotation_command.lua`'s own bespoke waiting/timeout machinery is untouched.

**Files changed**:
- `lua/vantage/model_command.lua`
- `lua/vantage/state.lua` — `agent_label()`
- `nvim/tests/vantage_spec.lua`

---

## 3A. Optional UI components — headless callback for markdown commands (score: 6) ✅ Partially implemented

**Completed**: 2026-08-19

**What was built**:
- `model_command.lua`'s `handle_markdown_response`/`request_markdown` now accept an optional `callback(err, result)`. When present, the markdown float is skipped entirely and the caller gets `{ markdown = ... }` (or an error string) directly instead.
- Applied to the four commands built on that shared helper: `explain(opts)`, `question(opts)`, `agent_cancel(opts)`, `reset_agent_session(opts)`. `opts.callback` threads through unchanged from `init.lua` → `commands.lua` → `model_command.lua`, following the existing `opts` pass-through pattern (no new dispatch module).
- `agent_cancel`/`reset_agent_session` gained `opts` parameters (previously took none) purely to carry the callback; their ex-commands are untouched.
- Test: `explain with a callback skips the markdown float` in `vantage_spec.lua`.

**Files changed**:
- `lua/vantage/model_command.lua`
- `lua/vantage/commands.lua`
- `lua/vantage/init.lua`
- `nvim/tests/vantage_spec.lua`
- `README.md` — Lua API table

**Deliberately out of scope**: `edit`, `search`, `generate_walkthrough`, `status`, and `annotation_command.lua` — see remaining gap noted in `improvement-ideas.md` 3A.

---

## 2C. Codex subscription support (score: 2) ✅ Already works

**Assessment**: Codex subscriptions work out of the box via the Pi SDK. The README already documents `openai-codex` as a provider with Pi OAuth auth (`npx @earendil-works/pi-ai login openai-codex`). No code changes were needed.

**Remaining gap**: Discoverability only. If this becomes important, a `:VantageAuth` command could walk through the Pi login flow.
