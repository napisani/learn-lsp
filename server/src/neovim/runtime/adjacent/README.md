# Adjacent: borrow Pi context, not its live execution

This runtime makes Vantage a companion to a running Pi conversation. The
adjacent agent owns the authoritative conversation; Vantage must not build a
separate long-lived conversation that gradually diverges from it.

[agent.ts](agent.ts) implements `AdjacentAgentRuntime` independently of
`PiAgenticRuntime`. It composes [PiAgentCommon](../pi-agent-common.ts) to preserve
the same prompts, tool restrictions, streaming, and result contracts.

## One fresh fork per action

Every agent action, including annotations, requests a snapshot, creates a new
isolated Pi session from it, runs the Vantage command, and disposes that fork.
Pi 0.85 requires a private temporary session file to seed the branch; Vantage
removes it when the fork is disposed.
There is no retained Vantage branch and no automatic merge back into the parent.
A later action does not inherit an earlier Vantage answer.

When Pi is idle, the snapshot reflects its current active branch. While it is
busy, Vantage uses the latest completed turn, including that turn's tool results,
and excludes the turn still in progress. The extension retains one serialized
snapshot, refreshed before a new request and at `turn_end` rather than waiting
for the entire agent run to finish. Session output labels busy-parent snapshots.

A new conversation can supply an empty starting snapshot. If the extension is
loaded mid-turn before observing a complete boundary, the request fails until a
safe snapshot is available. Never copy a partial tool-call sequence merely to
make a request succeed.

## Process-to-process communication

- [extension.ts](extension.ts) runs inside interactive Pi and owns snapshot
  capture plus socket startup/shutdown across reloads and session replacement.
- [transport.ts](transport.ts) implements owner-only Unix sockets, exact canonical
  workspace matching, discovery probes, bounded messages, and IPC deadlines.
  Socket names use workspace hashes and process IDs, not pane identity.
- [protocol.ts](protocol.ts) defines versioned `probe` and `snapshot` messages.
- [session.ts](session.ts) runs in Vantage, imports the native branch entries,
  validates the source leaf, and creates the disposable session.

**Only discovery and snapshot transfer cross IPC.** Inference, tool execution,
and streaming happen in the Vantage backend—not in the adjacent Pi process.
No tmux, Herdr, terminal scraping, or keystroke injection is involved.

## What a fork does and does not inherit

It inherits the source branch's native conversation entries, including
compaction and branch summaries, plus the parent's model and thinking level.

It does not inherit live extension code, extra tools, custom system-prompt
execution, or transient context hooks. Vantage reloads its normal workspace
instructions and skills with extensions disabled for the fork. Auth is resolved
locally through Vantage's Pi configuration; credentials are not sent over IPC.
A provider available only through a parent's live extension is not transferred.

Cancellation and reset affect only Vantage's request/output state. Conversation
isolation is not filesystem isolation: edit requests still change the shared
workspace. The socket protects against other OS users, not other processes
running as the same user.

## Selection is outside this runtime

Explicit `agent.runtime = "adjacent"` requires a bridge and never silently
creates a blank Pi conversation. Without an explicit socket, it discovers a
matching bridge for each request.

`agent.runtime = "adjacent-or-pi"` is handled by
[selection.ts](../selection.ts), which probes once and pins either an adjacent
socket or the owned Pi runtime for the backend lifetime. A later disconnect must
not cause this module to switch contexts silently.

There is no adjacent completion implementation: completion-mode actions remain
single-call [Pi completions](../pi/README.md#completion-runtime) without inherited
conversation history. See the [runtime overview](../README.md).
