# Pi: Vantage-owned execution

This directory provides Vantage's self-contained Pi integration. It does not
require a running adjacent agent, inspect another conversation, or discover
terminal panes.

## Agent runtime

[agent.ts](agent.ts) implements `PiAgenticRuntime` for `agent.runtime = "pi"`,
which remains the default. It is also the implementation selected when
`adjacent-or-pi` initially finds no bridge.

Vantage owns the conversation:

- Non-annotation actions reuse an in-memory buddy session while the workspace
  stays the same, so earlier Vantage turns remain available to later actions.
- The store holds one buddy session at a time; changing workspaces replaces it.
- Annotations use a separate transient session and do not enter buddy memory.
- Reset disposes the retained session and clears Vantage output history.
- Session creation uses Vantage's configured provider, model, reasoning, and
  auth. Session state is not persisted to Pi session files.

[session-store.ts](session-store.ts) implements retention, active-request
tracking, and output history. The adjacent runtime also uses its bookkeeping,
but never uses it to retain a fork between actions.

The agent composes [PiAgentCommon](../pi-agent-common.ts) for command behavior.
This module owns session creation and reuse, not a second copy of prompts,
submit-tool dispatch, or response handling. The common code applies the active
tool set for each command even though the buddy session registers the broader
set needed across commands.

## Completion runtime

[completion.ts](completion.ts) implements `PiCompletionRuntime`: a single model
completion with no agent session, tools, or agent loop. It uses the supplied
prompt and optional system prompt, not buddy-session or adjacent-session memory.

This is intentionally independent of `PiAgenticRuntime` and `PiAgentCommon`.
Sharing model/auth resolution through [model-target.ts](model-target.ts) does
not justify adding session management or submit tools to the completion path.
Completion calls still use this implementation when the configured agent is
adjacent.

## Supporting modules

- [module.ts](module.ts): the shared dynamic import of the ESM Pi SDK.
- [model-target.ts](model-target.ts): model lookup and auth-path resolution.
- [defaults.ts](defaults.ts): Vantage's default model target.
- [request-cancellation.ts](request-cancellation.ts): cancellation spanning
  agent session setup and prompting, also used by the shared agent code.

## Keep this distinct from adjacent

Do not add socket discovery, parent-session forking, or fallback-on-disconnect
here. The [adjacent runtime](../adjacent/README.md) owns a different conversation
lifecycle; [selection.ts](../selection.ts) owns automatic selection. Selecting
Pi as a fallback does not turn it into a degraded adjacent runtime—it remains
the normal Vantage-owned agent.

See the [runtime overview](../README.md) for the two runtime settings and shared
code ownership.
