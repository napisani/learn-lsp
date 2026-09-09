# Runtime intent and ownership

These modules separate **where conversation context comes from** from **how a
Vantage command executes**. Sharing Pi as an SDK does not make the runtimes
interchangeable.

## Two different runtime settings

- `agent.runtime` chooses the agent implementation: `pi`, `adjacent`, or the
  `adjacent-or-pi` selection policy. `development` is an internal test option.
- A command's `runtime = "agent" | "completion"` chooses a tool-using agent versus
  a single model completion. It does not select the conversation source.

| Implementation | Intent | Conversation ownership |
| --- | --- | --- |
| [Pi agent](pi/README.md) | A self-contained Vantage coding companion | Vantage owns an in-memory buddy session; annotations use separate transient sessions. |
| [Adjacent agent](adjacent/README.md) | Ask about the work happening in a running Pi conversation | The adjacent Pi owns the source conversation; each Vantage action gets a disposable fork. |
| [Pi completion](pi/README.md#completion-runtime) | One model call without agent machinery | No agent session, tools, or inherited adjacent conversation. |
| [Development](development/README.md) | Exercise contracts and UI flows without a model | Synthetic responses, not a real conversation. |

## Selection is not another agent runtime

[selection.ts](selection.ts) resolves `adjacent-or-pi` on the first agent-runtime
command, including status or skill lookup. Completion-mode commands bypass this
selection because they do not use the agent conversation source:

- One adjacent bridge: select `adjacent` and pin its socket.
- No bridge: select `pi`.
- Ambiguity, permissions, timeout, or protocol failure: surface the error.

A successful choice lasts for the backend process, not a request or workspace.
Concurrent initial commands share detection. Failed or cancelled detection can
be retried. Resetting agent state does not reset this choice; restart the backend
to reselect. Later agent arrival or disappearance must not silently switch the
conversation source.

Only the choice and socket are cached, not the entire runtime configuration.
[agent-factory.ts](agent-factory.ts) constructs the selected implementation using
current options and its separate session store. Explicit `pi` and `adjacent`
bypass automatic selection.

[completion-factory.ts](completion-factory.ts) selects completions independently:
production completions still use Pi even if the agent choice is adjacent.

## Shared behavior, composed rather than inherited

[pi-agent-common.ts](pi-agent-common.ts) owns command prompts, lens handling,
command-specific tool restrictions, submit tools, streaming, result handling,
cancellation orchestration, and output history. Both production agent classes
compose it.

Each concrete agent supplies its session lifecycle: acquire a session, decide
whether to track the request, and release or retain the session. The common
module must not discover sockets, choose a runtime, create buddy sessions, or
contain adjacent-specific branches.

## Where changes belong

- Command behavior shared by both agents: `pi-agent-common.ts`.
- Owned-session creation/reuse: `pi/agent.ts`.
- Parent snapshots, IPC, or fork lifetime: `adjacent/`.
- Initial fallback policy: `selection.ts`, not either agent implementation.
- Single-call model behavior: `pi/completion.ts`, not agent common code.
- Synthetic contract fixtures: `development/`.

Keep production behavior identical across agent implementations where only the
context source differs. Do not achieve that by making one concrete runtime a
subclass or mode of the other.

For configuration and user commands, see the [plugin README](../../../../README.md).
