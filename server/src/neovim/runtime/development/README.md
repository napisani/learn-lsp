# Development: synthetic runtime responses

These implementations exercise Vantage's request/response contracts and UI flows
without model credentials, network inference, or a running adjacent agent.
They are test/local-harness doubles, not a cheaper production model or an error
recovery mode.

- [agent.ts](agent.ts) implements `DevelopmentAgentRuntime` with predictable
  explanations, annotations, search locations, and session-status responses
  derived from request inputs.
- [completion.ts](completion.ts) implements `DevelopmentCompletionRuntime` with
  a synthetic completion containing a preview of the supplied prompt.

The backend factories select these when `agent.runtime = "development"`.
This TypeScript runtime setting is distinct from Neovim's
`backend.mode = "development"`, which uses the separate Lua development backend
instead of the Node transport.

## Intent and limits

There is no real agent conversation, tool loop, IPC discovery, or provider auth.
The agent does not compose `PiAgentCommon`: bypassing production model machinery
is the point of this implementation.

Do not assume every operation is side-effect-free. The simulated edit only
acknowledges completion, but walkthrough generation writes a fixture artifact to
`.vantage/walkthrough.json`. Use a temporary workspace when testing that path.
Cancel, reset, and session output are synthetic acknowledgements, not evidence
that production cancellation or session retention works.

## Guardrails

- Keep responses predictable and compatible with the public result contracts.
- Do not introduce live model calls or adjacent-agent dependencies here.
- Never automatically fall back to development responses after a production
  runtime fails; that would report simulated success as real work.
- Test real session ownership, cancellation, and IPC in the corresponding
  [Pi](../pi/README.md) and [adjacent](../adjacent/README.md) tests, not solely
  through this double.

See the [runtime overview](../README.md) for production runtime selection and
shared-code ownership.
