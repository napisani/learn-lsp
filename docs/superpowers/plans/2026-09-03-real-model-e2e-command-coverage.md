# Real-Model E2E Command Coverage Implementation Plan

**Goal:** Turn `make e2e-model` into an isolated, fixed-model, paid command-coverage tour for every Vantage command and its runtime/option paths.

**Design:** `docs/superpowers/specs/2026-09-03-real-model-e2e-command-coverage-design.md`

**Tech stack:** Make, headless Neovim/Lua, Vantage stdio backend, Pi.

### Task 1: Fixed isolated runner

**Files:**
- Modify: `Makefile`
- Modify: `nvim/dev/init.lua`

- [x] Replace the paid target's configurable model defaults with fixed `openai-codex/gpt-5.6-luna` and `reasoning = "low"` for both agent and completion paths.
- [x] Stage a fresh `.nvim-dev/e2e/workspace` from `examples/e2e-codebase` before every execution, initialize a clean git worktree, and run Neovim from that directory.
- [x] Keep timeout variables configurable and retain exclusion from normal tests.
- [x] Verify target expansion without invoking the model.

### Task 2: Complete the headless command driver

**Files:**
- Modify: `nvim/tests/e2e_all_commands_spec.lua`

- [x] Introduce reusable helpers for commands, floats, prompt/composition buffers, ranges/visual selection, artifacts, fixture restoration, and errors.
- [x] Cover every `CommandNames.all` command; cover `agent` and `completion` for Explain, Question, Edit, and Annotate.
- [x] Exercise direct/prompt, range/visual, annotation scope/max, promoted output, named model, history, composition, monitor, health, debug log, and walkthrough paths through Ex commands/Neovim input.
- [x] Derive and assert complete command coverage from `CommandNames.all`.
- [x] Preserve useful local evidence in the artifact and fail nonzero on an operational failure.

### Task 3: Fixture and documentation

**Files:**
- Modify/add: `examples/e2e-codebase/**`
- Modify: `README.md`

- [x] Keep the existing nested fixture template as the stable command/monitor/walkthrough workspace; the target now stages it before each run.
- [x] Update the README's E2E invocation/documentation to describe the fixed paid model and disposable staged workspace.

### Task 4: Deterministic verification

- [x] Run `npm run lint`.
- [x] Run `npm run test:mvp`.
- [x] Do not run `make e2e-model` unless explicitly requested; it costs money.
