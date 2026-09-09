# Real-Model E2E Command Coverage

Status: approved
Date: 2026-09-03

> This design supersedes the real-model E2E details in
> `2026-06-12-local-model-e2e-all-commands-design.md`. The older document
> describes the initial, smaller command tour and configurable cheap-model
> target; the current suite has more commands and must instead be a deliberate,
> fixed paid check.

## Purpose

Extend the existing `make e2e-model` suite so one headless, real Neovim session
exercises every registered Vantage command and its relevant user-visible option
paths. The test is a local confidence check for the integration from Ex command
through Vantage, its stdio TypeScript backend, and the Pi runtime. Its purpose
is to catch small operational failures; it does not grade model prose.

## Goals

- Invoke every command listed by `lua/vantage/command_names.lua` through
  Neovim's command layer.
- Exercise `agent` and `completion` runtime overrides for each command that
  supports them: Explain, Question, Edit, and Annotate.
- Exercise supported option and interaction branches: line/range/visual scope
  where meaningful, inline arguments, prompt-buffer submission, annotation
  scope/max, output split/vsplit promotion, and named model selection.
- Run against an isolated, nested mini-codebase that behaves like a normal git
  workspace.
- Fail on command errors, backend error surfaces, timeouts, missed local
  effects, or incomplete command coverage; ignore result prose quality.
- Leave a JSON artifact sufficient to diagnose a paid-test failure.

## Non-goals

- Do not add this test to `test`, `test:mvp`, `make check`, or CI.
- Do not assert model wording, exact search locations, or semantic edit quality
  beyond the local state needed to prove an action completed.
- Do not change production plugin behavior or replace deterministic Lua and
  backend tests.
- Do not make model selection configurable for this target: its purpose is to
  continuously exercise one known model/runtime configuration.

## Fixed real-model configuration

`make e2e-model` uses only:

- provider: `openai-codex`
- model: `gpt-5.6-luna`
- reasoning: `low`

The development init receives this configuration for both Pi execution paths:
`agent.options.reasoning = "low"` and `completion.options.reasoning = "low"`.
The target does not accept provider, model, or reasoning overrides. Timeout
knobs remain configurable because they change reliability, not the tested
model or cost profile.

## Isolated Neovim and fixture

`examples/e2e-codebase/` stays a small read-only template. It contains nested
Lua files with stable cross-file references and any Vantage fixture metadata
needed by the scenario.

Before every run, `make e2e-model` recreates
`.nvim-dev/e2e/workspace` from that template. The staged copy, including a
minimal `.git` directory, is the sole Neovim cwd and workspace root. Every
possible agent edit, generated walkthrough, history record, debug log, and
artifact remains below `.nvim-dev/e2e/`; the repository template is never
modified.

The target compiles the TypeScript backend then starts exactly one headless
Neovim instance with `--noplugin -u nvim/dev/init.lua`. The development init
prepends this checkout's runtime path and calls Vantage setup; no user config
or unrelated plugin is loaded.

## Command-tour harness

`nvim/tests/e2e_all_commands_spec.lua` remains a standalone, stateful driver.
It invokes public behavior using Ex commands and Neovim input, never internal
Vantage implementation functions. Helpers own the repetitive mechanics:

- focus/reset the fixture buffer and select a line, range, or visual region;
- open, fill, toggle, submit, and close prompt/composition buffers;
- wait for a float, quickfix update, extmark, workspace write, or local state
  transition while detecting an error float early;
- stage/restore fixture content around edit cases;
- create an external workspace change and await monitor observation;
- capture per-case evidence and preserve a failure artifact.

The suite has one table-driven entry for every command in
`CommandNames.all`, plus explicit variant entries for each supported runtime
and option path. Its final coverage assertion derives the required command set
from `CommandNames.all`, compares it with the table's declared command names,
and fails for either a missing or stale entry. Adding or removing a registered
command therefore forces an E2E decision in the same change.

## Scenario coverage and structural assertions

### Model-backed commands

`VantageExplain`, `VantageQuestion`, `VantageEdit`, and `VantageAnnotate` each
run with both `runtime=agent` and `runtime=completion`. Range/visual cases are
used where applicable. Prompt-capable commands test both direct arguments and
prompt-buffer submission. The assertion is a non-error completed surface or
local state transition, not response content.

Completion edit must produce an observable buffer change. Agent edit may
change the workspace through Pi tools; the staged workspace is restored when a
later case needs stable fixture text. Annotation cases cover supported
scope/max options and assert that rendering can be cleared.

`VantageSearch` asserts a non-error quickfix population. `VantageGenerateWalkthrough`
asserts a generated `.vantage/walkthrough.json` and loadable pointers;
`VantageLoadWalkthrough` is also invoked directly.

### Local, presentation, and lifecycle commands

The same session covers every remaining registered command:

- lens set (explicit and prompted) and clear;
- annotation clear;
- status and live session output;
- cancel and agent reset;
- debug log and health;
- named model selection;
- output promotion in split and vsplit forms;
- composition open/send/clear;
- history selection and workspace/all clearing;
- monitor start, externally caused workspace change, and stop.

Each case declares the narrow local evidence that proves success: buffer/window
existence or content, lens/history state, cleared extmarks, a quickfix list,
monitor lifecycle/change observation, or a non-error Vantage surface. Commands
whose normal behavior safely does nothing in a particular state, such as idle
cancel, still run and must not error.

## Artifact and failure behavior

The test writes `.nvim-dev/e2e/model-all-commands.json` before and after every
case. It records:

- effective fixed model configuration and timeout settings;
- staged workspace and opened files;
- declared/observed command coverage;
- each case's command text, variant, lifecycle status, output/error, and local
  evidence;
- final buffer, float, quickfix, annotations, lens, history, monitor, and
  walkthrough state.

A synchronous Lua/Ex error, timeout, failed assertion, or coverage mismatch
records the failure then exits Neovim nonzero with the artifact path. Structured
agent actions may retry a model-shaped error up to three times, recording every
attempt, because model compliance is not the subject under test; an action that
still cannot produce its required local result fails. Later cases are skipped
only when continuing would make their state assertions meaningless.

## Validation

Implementing this design must preserve the ordinary deterministic gates:

```bash
npm run lint
npm run test:mvp
```

Do not execute `make e2e-model` as part of routine implementation validation:
it incurs model cost. A developer explicitly runs it when they want the live
integration check.

## Acceptance criteria

- `make e2e-model` stages a clean workspace and launches one isolated,
  headless Vantage Neovim instance.
- The target uses `openai-codex/gpt-5.6-luna` with low reasoning for both
  agent and completion runtime calls.
- Every current `CommandNames.all` member has a scenario case, enforced by a
  coverage assertion.
- Explain, Question, Edit, and Annotate each have both runtime variants and
  their relevant option/prompt/range behavior is exercised.
- The suite asserts structural local effects and rejects operational errors
  without judging model prose.
- The paid target remains outside normal tests and CI.
- Every run leaves a useful artifact under `.nvim-dev/e2e/`.
