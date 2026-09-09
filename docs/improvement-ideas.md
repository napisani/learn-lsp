# Vantage Improvement Ideas

Refined from original brainstorm. Organized by category with architectural context, Neovim best practices, and concrete implementation notes.

Each goal has a **conviction score** (10 = high conviction, must-have; 1 = weak thought, needs more signal). Scores reflect conviction that the idea is the right thing to do *at its current priority level*, not raw importance.

Completed items are tracked in `completed-improvements.md`.

---

## Architecture Context

Vantage has two layers:
- **Lua frontend** (`lua/vantage/`): commands, floating windows, virtual annotation blocks, prompt buffers, context gathering, completion integrations.
- **TypeScript backend** (`server/src/neovim/`): stdio JSON-RPC process, Pi coding-agent SDK integration, session management, prompt construction, submit-tool contracts.

The Lua↔backend boundary is the critical seam. The backend owns agent runtime behavior; the Lua side owns editor integration. The `backend.request()` module is the single transport layer — every command flows through it.

Key architectural invariants to keep in mind when evaluating improvements:
- Singleton buddy session per workspace/backend process (non-annotation commands share it).
- Transient sessions for annotations (no buddy memory, no session state leakage).
- Submit-tool contracts for structured results (edit, search, annotations, walkthrough) — the agent cannot call Pi `edit`/`write` directly.
- Read-only agent tools (`read`, `grep`, `find`, `ls`) plus Vantage-owned submit tools.
- Agent Context File as the sole integration point with adjacent coding agents.
- The `AgentRuntime` interface (`agent-runtime.ts`) is the single abstraction over Pi — there are no other runtime backends.

---

## Category 1: Observability & Debuggability

### 1B. Notification & loading-state polish (score: 5) ✅ Implemented (simplified scope)

**Completed**: 2026-08-19 — see `completed-improvements.md`.

**What shipped vs. what didn't**: `explain`/`question`/`edit`/`search`/`generate_walkthrough`/`agent_cancel`/`reset_agent_session` now notify "requesting from `<agent>`..." on start and a timing-annotated completion/failure message, gated on the [[3A]] `opts.callback` (headless callers get silence, not notifications). Deliberately **not** built**: a shared stateful `vantage.progress` module, the `waiting_message_ms` "still waiting" mid-flight nudge for these commands, and a `VantageProgress` autocmd. Those add real complexity (timers, per-call handles, a new config key) for a problem — long silent mid-flight waits — that these commands don't commonly hit; annotate already has its own bespoke version of that machinery for its longer-running case. Revisit only if this actually comes up in practice.

---

## Category 2: Session Management

### 2A. More disciplined session management (score: 5) ✅ Implemented (simplified scope)

**Completed**: 2026-08-19 — see `completed-improvements.md`.

**What shipped vs. what didn't**: `:VantageStatus` now shows session age, turn count (excluding transient annotation runs), last command type, model target, and output-history count against its cap. Folded into the existing `:VantageStatus` command rather than a new `:VantageSessionInfo`, per this section's own "or fold into" alternative. Deliberately **not** built: `User` autocmds for lifecycle events (no precedent in the codebase and nothing currently listens), and the `agent.session.auto_reset`/`agent.session.max_age_ms` config options (speculative "consider" suggestions with no concrete driving need yet). Revisit those only if a real consumer or complaint shows up.

---

### 2B. Session persistence & resume (score: 2) 🆕

**Goal**: Resume a Vantage session after Neovim restart.

**Architectural fit**: Sessions are currently in-memory only (`In-Memory Agent Session` via `SessionManager.inMemory(root)`). To persist, you'd need Pi's disk-backed session manager (if it exists) or serialize the session transcript.

**Neovim best practice**: Persisted sessions in Neovim plugins are fragile — format changes, plugin updates, and stale state cause problems. The safer pattern is "persist the prompt history, recreate the session" rather than "persist the raw session state."

**Concrete suggestions**:
- **Defer** until session output is solid. Users need to see what a session contains before they'll trust persistence.
- If implemented, persist to `.vantage/sessions/` with a workspace-scoped directory.
- Store structured turn data (prompt, response summary, command type) rather than raw Pi session state.
- Add `:VantageSessionResume` that lists available sessions and lets the user pick one.
- Start with a "last session" auto-resume option before building a full session picker.

---

## Category 3: UI & Interaction

### 3A. Optional UI components (score: 6) ✅ Partially implemented

**Goal**: Commands should be invocable without any UI, allowing callers to build their own UI on top.

**Completed**: 2026-08-19 — for the pure markdown-response commands. See `completed-improvements.md`.

**Remaining gap**: `edit`, `search`, `generate_walkthrough`, and `status` still couple the request to their side effects (buffer mutation, qflist population, walkthrough reload, multi-source combining, `vim.notify`). Headless support for those would need per-command design (e.g. does a headless `edit` still mutate the buffer, or only report the replacement text?) rather than the uniform `opts.callback` pattern used for markdown-only commands. `annotation_command.lua` likewise still couples rendering with display.

---

## Category 4: Quick Completion Runtime

### 4A. Completion source integration (score: 5) 🆕

**Goal**: Expose the completion runtime as a cmp/blink source for inline suggestions (comment completion, quick rephrase, test hints).

**Architectural fit**: The `CompletionRuntime` interface and `complete` backend method already exist. A completion source would be a cmp/blink provider that calls `backend.request("complete", ...)` and maps `CompletionResult.text` to completion items.

**Neovim best practice**: Follow the existing `vantage.integrations.blink_skills` and `vantage/completion/skills.lua` pattern — optional peer integrations that opt in via config, never hard dependencies.

**Concrete suggestions**:
- Add `vantage/integrations/completion_source.lua` exposing a cmp source and a blink provider.
- Config: `agent.completion.enabled`, `agent.completion.model` (smaller/faster model than the main one), `agent.completion.max_tokens`.
- Debounce triggers on idle (`CursorHoldI`) to avoid spamming the backend during typing.

---

## Category 5: Cross-Cutting Neovim Best Practices

### 5A. Health check command (score: 6) ✅ Implemented (simplified scope)

**Completed**: 2026-08-19 — see `completed-improvements.md`.

**What shipped vs. what didn't**: `lua/vantage/health.lua` implements the standard `:checkhealth vantage` entry point (Neovim looks up `<name>.health` automatically) plus a `:VantageHealth` alias command, checking backend readiness (node + compiled server script, or dev mode), model target resolution, Pi auth file presence, and Agent Context File status — all built from state the plugin already tracked, no new plumbing. Dropped: "Completion plugin integrations available (blink.cmp, nvim-cmp)" — stale, same reason as [[4A]]; Vantage's completion is a prompt-driven `:VantageComplete` command, not a cmp/blink source, so there's no such integration to check.

---

### 5B. Autocmd events (score: 5) ⏸️ Deferred

**Deferred**: 2026-08-19 — speculative infrastructure with no current consumer in this repo (same reasoning applied when autocmds were dropped from [[1B]] and [[2A]]'s scope). Revisit if a concrete integration (statusline plugin, fidget.nvim, a companion plugin) actually needs to observe these events.

**Suggestion**: Fire custom `User` autocmds for key lifecycle events so other plugins can react:
- `VantageCommandStarted` — before any model-backed command sends to backend.
- `VantageCommandCompleted` — after successful response.
- `VantageSessionReset` — after buddy session cleared.
- `VantageAnnotationsRendered` — after annotation blocks placed.

Pattern: `vim.api.nvim_exec_autocmds("User", { pattern = "VantageCommandStarted", data = { command = "explain" } })`. This is the standard Neovim extension point (used by lazy.nvim, fidget, etc.).

---

### 5C. Statusline component (score: 4) 🆕

**Suggestion**: Expose a `vantage.statusline()` function that returns a formatted string for statusline plugins:
```lua
require("lualine").setup({
  sections = {
    lualine_x = { require("vantage").statusline() },
  },
})
```
Should show: model target, active session status, annotation count, current lens. The data already exists in `state.lua` — just needs a formatted accessor.

---

### 5D. Workspace-scoped configuration overrides (score: 4) 🆕

**Suggestion**: Support `.vantage/config.lua` (or `.vantage/config.json`) in workspace roots that overrides specific global settings. The `agent_context` module already resolves workspace-relative paths — extend this pattern. Useful for: different default models per project, different annotation budgets, different lenses.

---

## Priority Sequencing

Based on conviction scores, architectural fit, and dependency relationships:

### Phase 1: Foundation (highest impact, least dependency)
1. ~~**4A: Completion source integration**~~ — superseded: completion shipped as a single-turn `:VantageComplete` prompt command (see `completed-improvements.md` 4A), not a cmp/blink source. This section's cmp/blink framing does not match actual intent.
2. **3A: Optional UI / headless API** (score 6) ✅ Partially done — markdown-response commands (`explain`, `question`, `agent_cancel`, `reset_agent_session`) support `opts.callback`. `edit`/`search`/`generate_walkthrough`/`status`/annotations remain.

### Phase 2: Polish (medium effort, high value)
3. **1B: Notification/loading polish** (score 5) ✅ Done (simplified — see `completed-improvements.md`).
4. **2A: Disciplined session management** (score 5) ✅ Done (simplified — see `completed-improvements.md`).
5. **5A: `:VantageHealth`** (score 6) ✅ Done (simplified — see `completed-improvements.md`).
6. **5B: Autocmd events** (score 5) — Enables integrations.

### Phase 3: Long-term (high effort, deferred)
7. **2B: Session persistence/resume** (score 2) — Defer until session output is solid.
8. **5C: Statusline component** (score 4) — Nice-to-have.
9. **5D: Workspace-scoped config** (score 4) — Nice-to-have.

---

## New Ideas Discovered from Architecture Review

### 6A. Backend health checks & auto-reconnect (new, score: 6)

The stdio backend process can die silently. The `on_exit` handler in `backend.lua` calls `fail_pending` but doesn't attempt restart or notify the user proactively.

**Suggestion**: Add automatic backend restart with exponential backoff. Show a persistent notification when the backend is down. Add `:VantageBackendStatus` to check health. This pairs with 5A (`:VantageHealth`).

---

### 6B. Annotation persistence as review artifacts (new, score: 3)

Annotations are ephemeral (cleared with `:VantageAnnotationClear`). For review workflows, persisting annotations could enable shareable review artifacts.

**Suggestion**: `:VantageAnnotateSave [path]` that writes current annotations to a structured file. `:VantageAnnotateLoad [path]` that restores them. Format: JSON with line numbers, text, and severity. This pairs well with the walkthrough system (which already persists to `.vantage/walkthrough.json`).

---

### 6C. Command aliasing & custom keymaps (new, score: 4)

Users may want to alias Vantage commands to shorter names or integrate them into existing keymaps.

**Suggestion**: Expose a `vantage.map_command(alias, command, opts)` Lua API that creates user-command aliases. Document common mappings:
```lua
vim.keymap.set("v", "<leader>va", ":VantageAnnotate<CR>")
vim.keymap.set("n", "<leader>ve", ":VantageExplain<CR>")
```
The `CommandNames` table already supports this pattern.
