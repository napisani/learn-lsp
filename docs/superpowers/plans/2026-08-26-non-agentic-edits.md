# Non-Agentic Edits Implementation Plan

> **For agentic workers:** Steps use checkbox (`- [x]`) syntax for tracking. Each task is independently verifiable — run its listed command before moving on.

**Goal:** Let `:VantageEdit` run through the completion runtime (one model call, no tools), and let a normal-mode edit reach anywhere in the current file via SEARCH/REPLACE blocks.

**Design:** `docs/superpowers/specs/2026-08-26-non-agentic-edits-design.md`

**Architecture:** Scope decides format. A visual selection keeps today's whole-section replacement; normal mode sends the whole file and gets back canonical aider-style SEARCH/REPLACE blocks. One parser serves both runtimes, because the agent's `submit_edits` tool takes the same block text as a string. Matching happens in Lua against the live buffer — the request is async, so backend-resolved line numbers would be stale on arrival.

**Tech Stack:** TypeScript backend (zod schemas, `node:test`), Lua plugin (custom harness under `nvim/tests/spec/`).

**Build order is bottom-up:** the pure parser and schemas first, then the prompt and tools, then handlers, then the Lua matcher, then wiring. Every task before task 8 is verifiable without touching a buffer.

---

### Task 1: SEARCH/REPLACE Parser

**Files:**
- Modify: `server/src/neovim/markdown-utils.ts`
- Test: `server/src/neovim/markdown-utils.test.ts` (new — this file has no tests today)

- [x] Write failing tests for `parseSearchReplaceBlocks(text)` returning `{ search, replace, filePath? }[]`:
  - canonical block: filename line, fenced, `<<<<<<< SEARCH` / `=======` / `>>>>>>> REPLACE`
  - multiple blocks in one response
  - **nested code fences inside the replace body** (avante issue #832 — a naive fence-splitter terminates the block early)
  - prose before/after/between blocks, since models editorialize
  - unterminated block → rejected, never silently truncated
  - empty `search` → rejected
  - CRLF normalized to LF
  - filename line absent → `filePath` is nil, block still parses
- [x] Implement the parser. Drive it off the `<<<<<<<`/`=======`/`>>>>>>>` markers, **not** off fence boundaries — that is precisely what breaks on nested fences.
- [x] Run `npm run test:backend`.

### Task 2: Protocol Schemas

**Files:**
- Modify: `server/src/neovim/protocol/params.ts`
- Modify: `server/src/neovim/protocol/results.ts`
- Modify: `server/src/neovim/protocol/index.ts`
- Test: `server/src/neovim/protocol/protocol.test.ts`

- [x] Write failing tests: `editSelection` params accept `runtime` and `scope`; omitting both still parses (back-compat); `EditHunksResultSchema` round-trips.
- [x] Add `runtime: RuntimeSchema.optional()` and `scope: z.enum(['selection','file']).optional()` to `EditSelectionParamsSchema`.
- [x] Add `EditHunksResultSchema` (`kind: 'edits'`, `hunks: { search, replace }[]`) and export it.
- [x] Delete the now-false comment at `params.ts:17` ("edit stays agent-only for now").
- [x] Run `npm run test:backend`.

### Task 3: File-Scope Prompt

**Files:**
- Modify: `server/src/neovim/prompts.ts`
- Test: `server/src/neovim/prompts.test.ts`

- [x] Write failing tests for `buildFileEditPrompt(params)`: contains the block format, the "if `submit_edits` is unavailable, return only the blocks" fallback, the current-file-only rule, and the match-exactly-once requirement.
- [x] Add a test asserting the file content is embedded **without line-number prefixes** — `buildAnnotationPrompt` numbers lines, and copying that here would make every SEARCH block unmatchable.
- [x] Implement `buildFileEditPrompt`. Leave `buildEditPrompt` untouched; it already carries its own no-tool fallback sentence.
- [x] Run `npm run test:backend`.

### Task 4: `submit_edits` Tool — NOT DONE (deferred)

> Superseded. Runtime, not scope, decides the mechanism: SEARCH/REPLACE exists
> because the completion runtime has no tools, so the agent path never emits
> blocks and needs no tool for them. These items were ticked in error; the tool
> was never written.

**Files:**
- Modify: `server/src/neovim/submit-tools.ts`

- [ ] Add `onEdits?: (hunks: EditHunk[]) => void` to `SubmitToolHandlers`.
- [ ] Define `submit_edits` with `parameters: Type.Object({ blocks: Type.String() })` — a string of block text, mirroring how `submit_edit` already passes `replacementText`. This is what keeps one format and one parser across both runtimes.
- [ ] Parse `blocks` through `parseSearchReplaceBlocks` and hand the hunks to `onEdits`.
- [ ] Register the tool alongside `submit_edit` and include it in the edit command's tool set.
- [ ] Run `npm run test:backend`.

### Task 5: Handler Routing

**Files:**
- Modify: `server/src/neovim/handlers.ts`
- Test: `server/src/neovim/handlers.test.ts`

- [x] Write failing tests: `editSelection` with `runtime: 'completion'` uses the completion runtime; `scope: 'file'` yields `kind: 'edits'`; `scope: 'selection'` (and omitted) yields `kind: 'edit'`.
- [x] Add `editSelection` to `COMPLETION_ELIGIBLE_METHODS`.
- [x] Add the `editSelection` case to `completionPromptFor`, branching on `scope`.
- [x] Add the `editSelection` case to `completionResultFor`, branching on `scope`.
- [x] Replace the stale comment above `COMPLETION_ELIGIBLE_METHODS` explaining the old exclusion.
- [x] Run `npm run test:backend`.

### Task 6: Match Ladder (pure Lua)

**Files:**
- Add: `lua/vantage/search_replace.lua`
- Test: `nvim/tests/spec/search_replace_spec.lua` (new)
- Modify: `nvim/tests/vantage_spec.lua` (register in `SPECS`)

- [x] Write failing tests against plain strings — no buffer API:
  - level 0: exact match resolves to the right range
  - level 1: differs only in trailing whitespace → resolves
  - level 2: block dedented to column 0 → resolves, and the **replacement is re-indented** by the same delta
  - no match → reported as a failure, not applied
  - two occurrences → ambiguous, skipped (never "take the first")
  - empty `search` → rejected
  - overlapping resolved ranges → the later hunk skipped and reported
  - ranges are resolved against the **original** text, so a hunk near the end is unaffected by one near the start
- [x] Implement `M.resolve(text, hunks)` returning `resolved` (range + adjusted replacement) and `failures` (reason + first search line).
- [x] Do **not** implement aider's first/last-line fuzzy strategy — the spec rejects it deliberately: flexible about whitespace, strict about content.
- [x] Run `npm run test:nvim`.

### Task 7: Applying Hunks

**Files:**
- Modify: `lua/vantage/buffer_edit.lua`
- Test: `nvim/tests/spec/edit_spec.lua`

- [x] Write failing tests: multiple hunks land on the right lines; application is bottom-up so earlier edits do not shift later ranges; **the whole multi-hunk edit is a single undo step** (`u` reverts every hunk).
- [x] Implement `M.apply_hunks(bufnr, resolved)`: sort bottom-up, `nvim_buf_set_lines` each, `undojoin` between them wrapped in `pcall` (it errors when it follows an undo).
- [x] Run `npm run test:nvim`.

### Task 8: Lua Wiring

**Files:**
- Modify: `lua/vantage/commands.lua`
- Modify: `lua/vantage/model_command.lua`
- Modify: `lua/vantage/state.lua`
- Test: `nvim/tests/spec/edit_spec.lua`

- [x] Write failing tests: `:VantageEdit runtime=completion` no longer errors; normal mode sends `scope = "file"` with the whole buffer; visual mode still sends `scope = "selection"` and replaces exactly the selection; partial failure applies what matched and reports the rest.
- [x] Swap `reject_runtime_option` for `with_runtime_option` on edit; delete the "does not support a runtime= option yet" error and the helper if it has no other caller.
- [x] Add `commands.edit.runtime = "agent"` to `state.default_config()`.
- [x] In `model_command.edit`, set `scope` from whether a range is present, and send the whole buffer as `selectedText` under file scope.
- [x] Switch on the response kind: `edit` → `buffer_edit.apply`, `edits` → `search_replace.resolve` then `buffer_edit.apply_hunks`.
- [x] Report failures via notify (count) plus `ui.show_markdown` (detail), matching every other Vantage failure path.
- [x] Run `npm run test:nvim`.

### Task 9: Prompt-Buffer Runtime Toggle

**Files:**
- Modify: `lua/vantage/model_command.lua`
- Test: `nvim/tests/spec/edit_spec.lua`

- [x] Write failing tests mirroring the existing question coverage: the edit prompt buffer binds `toggle_runtime`, renders the `[x] agent` segment, and the runtime chosen there reaches `params.runtime`. Assert via `nvim_buf_get_keymap` — per AGENTS.md, insert mode cannot be observed in headless runs.
- [x] Add `default_runtime`, `runtime`, `show_runtime_toggle = true`, and the `runtime` argument in `on_submit` to `model_command.edit` — the three lines `model_command.question` already has. No new machinery: `prompt_authoring` and `prompt_buffer` already take these generically.
- [x] Run `npm run test:nvim`.

### Task 10: Documentation

**Files:**
- Modify: `README.md`

- [x] Public API / command table: `:VantageEdit` accepts `runtime=`, and normal mode now edits the whole file.
- [x] Configuration Reference: `commands.edit.runtime`.
- [x] Document the normal-vs-visual split and the SEARCH/REPLACE format, including that a block naming another file is rejected.
- [x] Note the behavior change: normal-mode edit was cursor-line, is now whole-file.

### Verification

- [x] `npm run lint`
- [x] `npm run test:mvp`
- [x] Revert-probe the load-bearing guards: ambiguous-match rejection, overlap rejection, bottom-up ordering, single-undo, and the no-line-numbers prompt rule. Each must fail its test when removed.
- [x] Manual smoke in a scratch repo: visual edit replaces the selection; normal-mode edit applies multiple hunks; `u` reverts all of them in one step; `<C-r>` in the prompt buffer flips agent/completion.
