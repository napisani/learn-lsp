# Runtime Option (Agent vs. Completion) and Cancel Unification

Status: draft for user review
Created: 2026-08-20

## Goal

Today `explain`, `question`, `edit`, and `annotate` are hardcoded to run through the full agentic backend (`AgentRuntime` / `pi-runtime.ts`), even though a much lighter one-shot `CompletionRuntime` already exists and is currently reachable only through the standalone `complete` method / `VantageComplete` command. Meanwhile, cancellation is inconsistent: `annotate` tracks its own in-flight request and can be cancelled; `explain`/`question`/`edit` cannot be cancelled at all; and `agentCancel`/`VantageAgentCancel` only interrupts the persistent agent session, not a one-shot request.

This design:

1. Makes `runtime` (`"agent"` | `"completion"`) a first-class option on `explain`, `question`, and `annotate` — configurable per-command with a per-invocation override.
2. Removes `complete` / `VantageComplete` as a standalone command; its capability folds into `runtime=completion` on the three commands above.
3. Unifies cancellation: `VantageAgentCancel` is renamed to `VantageCancel` and cancels whatever request is currently tracked (regardless of which command or runtime started it) in addition to interrupting the agent session.
4. Generalizes `VantageStatus`'s request-status display to show whichever request is currently tracked, rather than being annotate-specific.

## Non-Goals

- `edit` does not get a `runtime` option in this slice. It stays agent-only; passing `runtime=completion` to `VantageEdit` is a client-side error, not a silent fallback. (Its structured output — a tool-called `submit_edit` payload — needs its own completion-mode design; deferred.)
- No change to `agentSessionReset` / `VantageAgentReset` — session reset is an agent-specific concept, orthogonal to this design.
- No change to `search` or `generate_walkthrough`. They keep their current agent-only, uncancellable behavior. (They could adopt the shared request tracker later at low cost, since the tracker itself is generic — not precluded by this design, just not done here.)
- No new "structured completion" capability (e.g. schema-aware JSON mode) on `CompletionRuntime`. Annotate's completion-mode output is extracted via a new text-parsing function, mirroring how `edit`'s agent-mode fallback (`parseEditPayload`) already works — not a provider-native structured-output feature.
- No backward-compatibility shims for `VantageComplete` or `VantageAgentCancel`. This is a breaking change to the public command surface, accepted because this is a single-maintainer plugin.

## Locked Decisions

### Runtime selection: per-command config default + per-invocation override

Every command's default is `"agent"` — this is a pure opt-in, and changes no existing behavior until a user sets a command's default to `"completion"` or passes an override.

```lua
require("vantage").setup({
  commands = {
    explain  = { runtime = "agent" },  -- override per-invocation: runtime=completion
    question = { runtime = "agent" },
    annotate = { runtime = "agent" },
    -- edit has no runtime field: always agent, always rejects runtime=completion
  },
})
```

Per-invocation override is a `runtime=agent` / `runtime=completion` token recognized among the command's `fargs` and stripped out before the remainder is used as prompt text (`question`) or annotate's existing scope/count option words (`line`/`visible`/`buffer`, a bare number):

```vim
:VantageExplain runtime=completion
:'<,'>VantageQuestion runtime=agent why does this leak?
:VantageAnnotate runtime=completion buffer
```

`VantageEdit` does not recognize this token at all. If a `runtime=` token is present in its args, `vantage.commands.edit` reports a client-side error ("Vantage: edit does not support runtime=completion yet") and does not send the request, rather than silently running agent mode anyway.

### Protocol change

Add an optional `runtime?: 'agent' | 'completion'` field to `ExplainSelectionParams`, `QuestionSelectionParams`, and `AnnotateRangeParams` in `server/src/neovim/protocol.ts`. `EditSelectionParams` does not get this field.

### Server dispatch change

Generalize the existing hardcoded `request.method === 'complete'` special-case in `handlers.ts`:

```ts
const COMPLETION_ELIGIBLE_METHODS = new Set(['explainSelection', 'questionSelection', 'annotateRange']);

const usesCompletion =
  request.method === 'complete' ||
  (COMPLETION_ELIGIBLE_METHODS.has(request.method) && request.params.runtime === 'completion');

if (usesCompletion) {
  const result = yield* runCompletionEffect(request, context);
  return { id: request.id, ok: true, result } satisfies BackendResponse;
}
// ...existing agent-runtime path, unchanged for editSelection and everything else
```

`runCompletionEffect` grows a per-method branch that reuses the *existing*, already-agent-decoupled prompt builders from `server/src/neovim/prompts.ts` (`buildExplainPrompt`, `buildQuestionPrompt`, `buildAnnotationPrompt` — the same functions `pi-runtime.ts` already calls before handing the prompt to the agent), calls `CompletionRuntime.complete()`, and shapes the result back into the exact `ExplanationResult` / `AnnotationResult` shape the client already expects. `model_command.lua` / `annotation_command.lua` do not need to know or care which runtime actually served a given request.

The `complete` method itself (used only internally now, no longer client-reachable via a command) can stay exactly as it is — it's already a `runCompletionEffect` call with a raw prompt.

### Annotate's completion-mode output

`annotateRange`'s agent-mode result comes from a `submit_annotations` tool call, which doesn't exist in completion mode (no tools). New parser `parseAnnotationsPayload` in `markdown-utils.ts`, alongside the existing `parseEditPayload`: the completion prompt instructs the model to emit annotations as a fixed markdown/JSON block, and the parser extracts `Annotation[]` from that block. This is the one genuinely new piece of logic in this design — everything else is wiring existing pieces together differently.

### Shared request tracker (client-side)

New module `lua/vantage/request_tracker.lua`, extracted from `annotation_command.lua`'s existing `annotation_request` table and its `begin_annotation_request` / `complete_annotation_request` / `cancel_annotation_request` functions, generalized from "the one annotation request" to "the one current Vantage request":

```lua
local tracker = require("vantage.request_tracker")

tracker.begin(agent, details)        -- starts tracking, bumps token, returns token
tracker.set_backend_id(token, id)    -- late-bound once backend.request() returns an id
tracker.complete(token)              -- marks done if token is still current; returns elapsed or nil
tracker.cancel(message_prefix)       -- cancels current if any: backend.cancel(id) + notify
tracker.status()                     -- current tracked request's status, for VantageStatus
```

Semantics carried over unchanged from `annotate`'s existing behavior: starting a new tracked request supersedes (via the token bump) whatever was previously tracked — there is exactly one "current" request across `explain`/`question`/`annotate`/`edit`, matching a single-editor, one-thing-at-a-time model. Progress events, waiting-message timers, and timeout scheduling (currently annotate-only) move into the tracker so all four commands get them, not just annotate.

`explain`, `question`, and `annotate` call `tracker.begin()` before issuing their request and `tracker.complete()` / rely on `tracker.cancel()` around it, replacing their current bare `backend.request()` calls. `edit` adopts the tracker too, for cancellability, even though it never sets `runtime`.

`annotation_command.lua` itself is refactored to use the shared tracker instead of owning its own copy of this state — its annotation-specific logic (candidate-line scoping, annotation limits, rendering) stays where it is.

### Cancel unification

`VantageAgentCancel` is renamed to `VantageCancel`; `M.agent_cancel` is renamed to `M.cancel`:

```lua
function M.cancel(opts)
  request_tracker.cancel("Vantage: cancelled request to")               -- generic in-flight cancel, any runtime
  request_markdown("agentCancel", context.current_line(), opts.callback) -- interrupt agent session too
end
```

Both run unconditionally on every `VantageCancel` invocation. `request_tracker.cancel()` is a no-op if nothing is currently tracked. The `agentCancel` RPC is presumed to already be a safe no-op server-side when the agent session isn't mid-turn (matches its current behavior when `VantageAgentCancel` is invoked with nothing running) — worth a quick confirmation at implementation time, not a design blocker.

### Status generalization

`VantageStatus` currently shows annotation-specific status via `annotation_command.status()`. This becomes `request_tracker.status()` — the currently-tracked request's status, regardless of which command started it. `annotation_command.lua`'s annotation-specific fields (received/rendered/skipped counts) stay in its own `details` table passed to `tracker.begin()`, so they still surface in status output for annotate requests; they're simply not special-cased at the tracker level.

## Command Surface Changes

| Before | After |
|---|---|
| `VantageComplete` / `M.complete` | removed |
| `VantageAgentCancel` / `M.agent_cancel` | renamed to `VantageCancel` / `M.cancel` |
| `VantageAgentReset` / `M.reset_agent_session` | unchanged |
| `VantageExplain` | gains `runtime=agent\|completion` |
| `VantageQuestion` | gains `runtime=agent\|completion` |
| `VantageAnnotate` | gains `runtime=agent\|completion` (alongside existing scope/count args) |
| `VantageEdit` | unchanged in capability; explicitly rejects `runtime=` |

Files removed: `lua/vantage/completion.lua`. `CommandNames.complete` and `CommandNames.agent_cancel` (renamed to `CommandNames.cancel`) updated in `lua/vantage/command_names.lua`.

Per `AGENTS.md`'s documentation guardrail, `README.md`'s Public API section must be updated in the same change: the `VantageComplete` row removed, `VantageAgentCancel` row updated to `VantageCancel` with its expanded cancel behavior, and `runtime=` documented under `VantageExplain`/`VantageQuestion`/`VantageAnnotate`.

## Testing Plan

- `nvim/tests/vantage_spec.lua`: existing annotate cancel-and-status tests should continue to pass unchanged once routed through the shared tracker (behavioral equivalence check). Add equivalent cancel/status coverage for `explain`/`question` (previously impossible to test since they weren't cancellable). Add a `runtime=completion` case for each of `explain`/`question`/`annotate` against the development backend. Add a case asserting `VantageEdit runtime=completion` errors client-side without sending a request.
- Server-side (`server/src/neovim/**/*.test.ts`): add `runCompletionEffect` branch coverage for `explainSelection`/`questionSelection`/`annotateRange`, and a case for the new annotation text-parser (valid block, malformed block).
- Manual: run `make test` (per `AGENTS.md` in the parent monorepo, `npm run lint && npm run test:mvp`) before considering this done.

## Rollout

This is a breaking change to the public command surface (`VantageComplete` removed, `VantageAgentCancel` renamed). No compatibility shim — accepted given single-maintainer usage. Implementation sequence, since annotate's completion-mode parser is the one genuinely new piece:

1. Extract `request_tracker.lua` from `annotation_command.lua`; refactor `annotate` to use it. No behavior change, verifies the extraction is safe.
2. Wire `explain`/`question` onto the tracker (gains cancellability, no runtime change yet).
3. Add the protocol `runtime` field, server dispatch generalization, and `runtime=completion` for `explain`/`question` (trivial — markdown-in, markdown-out either way).
4. Add the annotation text-parser and `runtime=completion` for `annotate`.
5. Rename `agent_cancel` → `cancel`, wire in the dual cancel behavior, remove `complete`/`VantageComplete`.
6. Update `README.md` Public API section.
