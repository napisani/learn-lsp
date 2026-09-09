# vantage.nvim

vantage.nvim is a Neovim-first assistant that supplements active development by explaining, annotating, editing, searching, and answering questions about code through a user-directed lens.

## Language

**Agent Task Context**:
A concise, read-only summary of what an adjacent coding agent currently understands about the active development task: goal, relevant files, constraints, decisions, hypotheses, and open questions.
_Avoid_: Session information, raw transcript, chat history

**Workspace Context Artifact**:
A workspace-local file that makes Agent Task Context available to Vantage. It is written by an adjacent agent or automation; Vantage reads it when present and works normally when it is absent.
_Avoid_: User notes, global memory, agent transcript

**Agent Context File**:
The Markdown Workspace Context Artifact at `.vantage/agent-context.md`, resolved relative to the current buffer's workspace root unless Vantage is configured otherwise.
_Avoid_: JSON context file, provider-specific session file

**Agent Context Freshness**:
The age of the Agent Context File, used as prompt metadata and optionally as a configurable reason to skip the file. Stale context is not an error.
_Avoid_: Required freshness, context validity

**Agent Runtime**:
The single AI execution boundary Vantage uses for model-backed and agentic work. It is backed by the Pi coding-agent SDK and exposes command-specific tool allowlists through Vantage-owned request contracts.
_Avoid_: Provider adapter, direct model adapter, model runtime

**Runtime Simplification**:
The decision to remove non-Pi model adapters and their user-facing configuration, development targets, tests, and docs so Vantage has one real Agent Runtime.
_Avoid_: Hidden legacy providers, deprecation-only cleanup

**Legacy Bounded Model Call**:
The removed single request/response runtime where Vantage owned prompt construction and Pi performed a simple model completion without the coding-agent SDK session/tool loop.
_Avoid_: Current Agent Runtime, Vantage Agent Session, agentic search

**Vantage Agent Session**:
A persistent conversation state owned by Vantage inside its backend process and scoped to a workspace, so each Model-Backed Command can become a user prompt in the same Pi-backed session.
_Avoid_: OS-level daemon, global Pi process, raw transcript

**Vantage Agent Session Scope**:
The identity boundary for a Vantage Agent Session: one singleton in-memory buddy session per backend/workspace process. Model Target, lens mode, buffers, and exact prompts do not create separate sessions.
_Avoid_: Per-buffer session, global session, lens-text session, model-scoped session

**Shared Command Session**:
The rule that explain, question, edit, and search commands share the same singleton Vantage Agent Session, while annotations use transient sessions and do not enter buddy memory.
_Avoid_: Per-command-family session, annotation memory, command-specific memory

**Model Target**:
The configured Pi provider/model pair used to choose a Pi SDK model, such as `openai/gpt-4o-mini`.
_Avoid_: Vantage provider, backend provider, adapter name

**Pi Provider**:
The provider name inside a Model Target, corresponding to the first argument of Pi's model lookup, such as `openai` or `anthropic`. It is not a separate Vantage execution adapter.
_Avoid_: Vantage provider, plugin provider, backend provider

**Agent Options**:
A freeform bag of Pi options supplied for the Agent Runtime. Vantage preserves the bag and does not inject model-option defaults; the Agent Runtime and Pi decide which options apply.
_Avoid_: Provider settings, Vantage-owned model defaults, shared completion options

**Agent Option Naming**:
The rule that Agent Options and Command Agent Options use Pi SDK camelCase field names, while Vantage-owned configuration keeps Lua-style snake_case names.
_Avoid_: Normalized option names, snake_case Pi options, mixed SDK option aliases

**Agent Credential Resolution**:
The rule that Vantage passes an explicit `apiKey` when configured, otherwise resolves Pi OAuth `auth.json` credentials for OAuth-backed Model Targets when available, and then leaves credentials unset so Pi or the provider can use environment or ambient authentication.
_Avoid_: Duplicated environment fallback table, provider-specific auth adapters, mandatory API keys

**Agent Auth Configuration**:
The optional `agent.auth` setup surface for Vantage-owned credential lookup, currently limited to an explicit Pi OAuth `auth.json` path. Without an explicit path, Vantage checks workspace-local auth files, then the Pi CLI default `~/.config/pi/auth.json`, then the older `~/.config/pi-ai/auth.json` location.
_Avoid_: General provider config, secret storage, login flow config

**Agent Configuration**:
The public Vantage setup surface for the Agent Runtime: a compact `agent` table containing the Model Target and Agent Options.
_Avoid_: Provider configuration, runtime configuration, Pi configuration

**Completion Options**:
A freeform bag of Pi options supplied for one-shot Completion Runtime calls. It is independent of Agent Options and is passed to Pi without Vantage model-option defaults.
_Avoid_: Shared agent options, provider-specific adapter settings, Vantage-owned sampling defaults

**Agent Configuration Module**:
The Lua module that normalizes Vantage setup state into the backend request config sent over the Neovim Backend Transport, including Agent Options, Completion Options, Agent Auth Configuration, Session Output History retention, Command Configuration, and Annotation Command Configuration.
_Avoid_: Scattered config serialization, protocol parser, runtime option merger

**Session Output Configuration**:
The public Vantage setup surface for retaining Session Output History entries, currently `agent.session_output.history_limit`.
_Avoid_: Agent memory configuration, persisted transcript configuration, provider cache setting

**Default Agent Runtime**:
The public default Agent Runtime configuration: Pi with the `openai/gpt-4o-mini` Model Target. Fake runtime behavior is reserved for development and tests.
_Avoid_: Fake default, provider-less default

**Development Agent Runtime**:
An internal deterministic Agent Runtime used only by tests and local development harnesses. It is not part of public Vantage configuration.
_Avoid_: Public fake provider, user fake runtime, documented fake setup

**Command Configuration**:
The top-level Vantage setup surface for command behavior, keyed by command family such as explain, question, edit, annotate, and search.
_Avoid_: Agent configuration for command behavior, scattered command globals

**Command Agent Options**:
A command-specific option bag layered onto Agent Options for an Agent Runtime command. Vantage does not supply fallback model-option values.
_Avoid_: Separate provider config, command provider

**Annotation Command Configuration**:
The command configuration for inline annotations, including annotation UI timing and command-specific Agent Options.
_Avoid_: Top-level annotations config, provider-specific annotation settings

**Annotation Command Module**:
The Lua module that owns the annotate and clear-annotations command behaviour: Annotation Scope selection, Annotation Budget calculation, candidate-line filtering, request lifecycle, cancellation, timeout handling, backend progress, rendering outcomes, and Annotation Status snapshots.
_Avoid_: Command registration module, annotation display adapter, status renderer

**Model-Backed Command**:
A Vantage command that asks the Agent Runtime for an answer, edit, explanation, annotation, or search response. Model-Backed Commands use Agent Task Context when the Agent Context File is available.
_Avoid_: Provider-Backed Command, agent-aware command, special context command

**Annotation Block**:
A lens-driven explanation anchored to a relevant code line, intended to be read as a small multi-line note rather than as a terse inline hint.
_Avoid_: Inline comment, virtual-text hint, code comment

**Annotation Budget**:
The upper bound on how many relevant code lines in a requested scope may receive Annotation Blocks. It limits visual noise but does not require the Agent Runtime to use every available slot.
_Avoid_: Required annotation count, line-by-line coverage, annotation density setting

**Percentage-Based Annotation Budget**:
The rule that multi-line Annotation Scopes derive their Annotation Budget from the number of relevant candidate lines, with minimum and maximum guardrails, so larger scopes can receive more coverage without becoming unbounded.
_Avoid_: Fixed annotation count, annotate every line, unbounded full-buffer annotation

**Relevant Annotation Line**:
A line inside the requested Annotation Scope that is eligible for Annotation Budget calculation because it contains non-comment, non-empty code according to Vantage's lightweight line heuristic.
_Avoid_: Treesitter relevance, semantic relevance, every line

**Discretionary Annotation Count**:
The rule that the Agent Runtime decides how many Annotation Blocks to return within the Annotation Budget, based on the lens and requested code scope.
_Avoid_: Fill every slot, fixed density, always annotate budget

**Discretionary Annotation Depth**:
The rule that each Annotation Block should be as deep as the lens and code warrant, usually ranging from a short note to a richer multi-line explanation, rather than using a uniform configured length.
_Avoid_: Fixed annotation height, one-line-only annotation, equal-length annotation

**Annotation Content Guardrail**:
The prompt-level rule that Annotation Block content should usually be one to four concise sentences, using more depth only when the active lens or anchored code warrants it.
_Avoid_: Paragraph annotation, bullet annotation, model-controlled display lines

**Virtual Annotation Surface**:
The rule that Annotation Blocks are explanatory overlays and must not modify buffer text, line contents, git diffs, formatter input, or copied source.
_Avoid_: Inserted annotation lines, generated comments, buffer mutation

**Annotation Presentation Ownership**:
The rule that the Agent Runtime owns Annotation Block content, while Vantage owns display concerns such as wrapping, placement, truncation, and visual styling.
_Avoid_: Model-driven layout, returned display lines, prompt-controlled wrapping

**Untruncated Annotation Blocks**:
The initial rendering rule that Vantage shows the full Annotation Block content returned by the Agent Runtime, relying on prompt guardrails instead of clipping oversized blocks.
_Avoid_: Hidden annotation text, collapsed annotation, default annotation clipping

**Annotation Scope**:
The requested code region Vantage asks the Agent Runtime to annotate: current line, explicit selection/range, visible viewport, or full buffer. Scope constrains where Annotation Blocks may be anchored.
_Avoid_: Global annotation, project annotation, unrelated file annotation

**Model-Backed Command Module**:
The Lua responsibility that turns a Neovim command invocation into scoped editor context, backend request parameters, and command-specific result handling for read-only and edit-producing Model-Backed Commands.
_Avoid_: Command wrapper, command controller, one-off command glue

**Backend Command Contract**:
The TypeScript responsibility that defines supported backend command names, request parsing, and runtime dispatch for Model-Backed Commands and Agent Session commands.
_Avoid_: Ad hoc method switch, duplicated protocol list, backend API surface

**Backend Transport Module**:
The Lua module that sends backend requests over stdio, tracks pending callbacks, dispatches progress events, and delegates local development responses to the Development Backend Adapter.
_Avoid_: Agent Runtime, protocol parser, development response fixture

**Development Backend Adapter**:
The Lua adapter that returns deterministic local responses for development backend mode without starting the TypeScript backend.
_Avoid_: Backend transport, fake public runtime, production agent adapter

**Submit Tool Contracts Module**:
The TypeScript module that defines Vantage-owned submit tools, validates submit-tool payloads, records accepted submit-tool events in Session Output History, and parses assistant fallback payloads for weaker tool-use models.
_Avoid_: Agent Runtime orchestration, prompt text, direct file mutation tool

**Buffer Edit Application**:
The Lua responsibility that validates and applies a single Agent Runtime replacement to the requested buffer range for `VantageEdit`.
_Avoid_: Raw model patch, multi-file agent edit, command-local mutation

**Status View**:
The Lua responsibility for rendering Vantage status markdown, including annotation status and Agent Context Status, without mixing display formatting into command orchestration.
_Avoid_: Inline status text, status command logic, diagnostics backend

**Prompt Authoring Module**:
The Lua module that turns inline command text or the floating prompt buffer into final prompt text for Question, Edit, and Search, including empty prompt handling and Prompt Reference expansion through the prompt buffer.
_Avoid_: Model prompt contract, lens prompt, completion engine

**Lens Precedence**:
The rule that a Vantage lens layers on top of Agent Task Context and has higher priority when they pull the model in different directions.
_Avoid_: Context override, agent-first prompting

**Context Compaction Responsibility**:
The rule that the producer of the Agent Context File is responsible for pruning and compacting it. Vantage may tail-read the file for prompt safety, but it does not summarize or rewrite Agent Task Context.
_Avoid_: Vantage summarization, consumer-owned compaction

**Context Snapshot**:
The preferred shape of the Agent Context File: a compact Markdown snapshot with Goal, Current Focus, Relevant Files, Decisions, Constraints, Open Questions, and Recent Progress sections. It is not an append-only log.
_Avoid_: Context log, transcript, changelog

**Agent Context Revision**:
The currently observed version of the Agent Context File, identified by file metadata and content when needed, so Vantage can tell whether task context has changed since the session last saw it.
_Avoid_: Always-fresh context, per-command context payload

**Context Update Turn**:
A low-priority prompt section that makes Agent Task Context available to a Vantage command when the Agent Context File is present.
_Avoid_: Repeated hidden mutation, command replacement, trusted instruction

**Session Output History**:
The bounded in-memory activity log rendered by `:VantageSessionOutput`, including buddy session requests and transient annotation activity.
_Avoid_: Durable transcript, provider memory, prompt cache

**Pi Session Affinity**:
The coding-agent SDK session state owned by Vantage's backend process for the singleton buddy session.
_Avoid_: Pi daemon, shared adjacent-agent session, persisted memory

**Successful Session Turn**:
A Vantage command turn whose Pi coding-agent request completed successfully and produced usable assistant content or accepted submit-tool output. Failed, cancelled, timed-out, annotation, or malformed submit-tool requests are not intentional buddy memory.
_Avoid_: Failed turn memory, cancelled turn memory, timeout transcript

**Agent Session Reset**:
The act of clearing the current singleton Vantage Agent Session by explicit user command when no agentic request is active.
_Avoid_: Context reset, backend restart, model reset

**In-Memory Agent Session**:
The lifetime rule for the initial Vantage Agent Session: session state lives only in the current Vantage backend process and is not persisted across Neovim restarts.
_Avoid_: Disk-backed session, durable chat history, restored Pi conversation

**Default Agent Session**:
The default session behavior: Vantage creates a singleton in-memory buddy session on first non-annotation Model-Backed Command and keeps it until explicit reset or backend restart.
_Avoid_: Opt-in memory, unbounded default session, persisted default session

**Agent Session Status**:
A Vantage-visible summary of the current Vantage Agent Session, such as active request, workspace, Model Target, and Session Output History count.
_Avoid_: Session transcript, session editor, Pi internals

**Context Trust Boundary**:
The rule that the Agent Context File is untrusted task context, not an instruction source. It must not override the selected code, lens, response format, or Vantage behavior.
_Avoid_: Trusted agent instructions, context as command

**Agent Context Status**:
A Vantage-visible summary of whether Agent Task Context is available for the current workspace, including the resolved path, freshness, size, and truncation state. It does not open or edit the Agent Context File.
_Avoid_: Context editor, context browser

**Agent Context Configuration**:
The small Vantage setup surface for Agent Task Context: enablement, workspace-relative path, tail-read byte limit, and optional freshness cutoff.
_Avoid_: Provider-specific agent settings, heading configuration

**Agent Context Reader**:
The Vantage Lua responsibility for resolving, reading, tail-limiting, freshness-checking, and reporting Agent Context Status for the current workspace.
_Avoid_: Backend context reader, provider context reader

**Agent Context Prompt Section**:
The prompt section that presents Agent Task Context to the model with source metadata, freshness metadata, truncation state, and explicit reminders about Lens Precedence and the Context Trust Boundary.
_Avoid_: Hidden instructions, merged lens text

**Agent Context Privacy Boundary**:
The rule that the Agent Context File is workspace/session state and should not be committed by default.
_Avoid_: Checked-in task context, shared session state

**Artifact-First Integration**:
The strategy of integrating adjacent coding agents through the Agent Context File before building agent-specific hooks, plugins, or native session integrations.
_Avoid_: Pi-only integration, session scraping, required hook integration

**Adjacent Agent Boundary**:
The rule that an adjacent coding agent and the Vantage Pi-backed Agent Runtime remain separate actors. The Agent Context File is the only shared mechanism, and information flows one way from the adjacent agent to Vantage.
_Avoid_: Shared Pi session, process consolidation, bidirectional agent bridge

**Useful Context Update**:
An update to the Agent Context File made when task state materially changes, such as a goal change, plan change, important discovery, decision, test result, focus shift, or handoff point.
_Avoid_: Per-event update, tool-call log update

**Agent Instruction Snippet**:
A copyable instruction for adjacent coding agents that explains how and when to maintain the Agent Context File.
_Avoid_: Agent-specific plugin requirement, manual user workflow

**Read-Only Context Consumption**:
The rule that Vantage reads the Agent Context File when present but does not create, edit, or initialize it during normal commands.
_Avoid_: Automatic context file creation, placeholder context file

**Prompt-Only Context Influence**:
The rule that Agent Task Context can shape model prompts but cannot change the Agent Runtime, Model Target, timeouts, or command behavior.
_Avoid_: Context-driven configuration, context-controlled model target

**Context Failure Tolerance**:
The rule that Model-Backed Commands continue without Agent Task Context when the Agent Context File is absent, unreadable, stale beyond configuration, or invalid. Details belong in Agent Context Status.
_Avoid_: Context-required command, context read failure

**Fake Context Signal**:
The fake-runtime behavior that exposes Agent Task Context presence and metadata for tests without echoing the full Agent Context File.
_Avoid_: Full fake context dump, untestable context plumbing

## Example Dialogue

Dev: "Can Vantage explain this function in the context of what Codex is working on?"

Domain expert: "Yes, if Vantage has Agent Task Context for the active task. It should use the distilled task summary, not the coding agent's raw conversation transcript."

Dev: "Where should that context live?"

Domain expert: "In a Workspace Context Artifact so the scope is the current project, independent of which coding agent produced it."

Dev: "What format should the artifact use?"

Domain expert: "Use the Agent Context File, a Markdown file at `.vantage/agent-context.md`, so adjacent agents can update it without custom integration code."

Dev: "What if the Agent Context File is old?"

Domain expert: "Treat Agent Context Freshness as metadata. Include fresh or unbounded context when present, and only skip old context if the user configured a max age."

Dev: "Which commands should use Agent Task Context?"

Domain expert: "Every Model-Backed Command should use it automatically when available; the user should not need separate agent-aware commands."

Dev: "What if the lens conflicts with the agent's task context?"

Domain expert: "Use Lens Precedence: the lens is the user's immediate instruction and layers on top of Agent Task Context."

Dev: "Who keeps the context file concise?"

Domain expert: "Context Compaction Responsibility belongs to the adjacent agent or automation that writes the file. Vantage should read it, not maintain it."

Dev: "What should the context file look like?"

Domain expert: "It should be a Context Snapshot: compact Markdown describing the current task state, not a growing record of every turn."

Dev: "Can the Agent Context File tell Vantage how to behave?"

Domain expert: "No. The Context Trust Boundary means the file informs Vantage about the task but cannot override Vantage's command semantics or the user's lens."

Dev: "How can I tell whether Vantage is using agent context?"

Domain expert: "Use Agent Context Status. Vantage should expose availability and freshness without turning the context file into an editor workflow."

Dev: "How configurable should agent context be?"

Domain expert: "Use Agent Context Configuration for the core safety and location settings only; keep the artifact convention stable."

Dev: "Which part of Vantage reads the context file?"

Domain expert: "The Agent Context Reader belongs in Lua, where Vantage already knows the current buffer and workspace. The backend receives the resulting context as request data."

Dev: "How should the context appear in model prompts?"

Domain expert: "Use an Agent Context Prompt Section so the model sees task context as lower-priority, untrusted background information."

Dev: "Should the Agent Context File be committed?"

Domain expert: "No. The Agent Context Privacy Boundary means `.vantage/agent-context.md` should be ignored by default because it is generated workspace state."

Dev: "How should Vantage integrate with Codex, Claude Code, opencode, and Pi?"

Domain expert: "Use Artifact-First Integration: every adjacent agent can produce the same Agent Context File, and agent-specific automation can come later."

Dev: "How often should adjacent agents update the file?"

Domain expert: "Use Useful Context Updates. The file should change when the task state changes, not after every tool event."

Dev: "How do I get different agents to participate without plugins?"

Domain expert: "Use the Agent Instruction Snippet so any adjacent agent that can write files can maintain the Agent Context File."

Dev: "Should Vantage create the context file?"

Domain expert: "No. Read-Only Context Consumption keeps Vantage from dirtying the workspace or taking over producer responsibilities."

Dev: "What does provider mean in Vantage configuration?"

Domain expert: "Provider means the Pi Provider inside the Model Target, not a swappable Vantage adapter. Vantage uses Pi as the Agent Runtime."

Dev: "Should Vantage use Pi's higher-level agent/session APIs now?"

Domain expert: "Yes. Use the Pi coding-agent SDK directly so Vantage can own a singleton buddy session, command-specific active tools, and Vantage submit-tool contracts."

Dev: "Should old Codex, Ollama, and ChatGPT adapters remain hidden for compatibility?"

Domain expert: "No. Runtime Simplification means removing those adapters and their Makefile targets, tests, and docs so the codebase converges on Pi as the only real Agent Runtime."

Dev: "Where do timeouts, reasoning level, and token budgets belong?"

Domain expert: "Put them in the freeform option bag for the runtime that should receive them. Agent Options and Completion Options are independent; command-specific options can further layer onto Agent Options."

Dev: "Should Pi option names be converted to Lua-style snake_case?"

Domain expert: "No. Use Agent Option Naming: Pi option tables keep SDK camelCase, and Vantage-owned settings keep snake_case."

Dev: "Who resolves API keys and OAuth credentials?"

Domain expert: "Use Agent Credential Resolution. Vantage passes `agent.options.apiKey` when configured; otherwise it can resolve Pi OAuth `auth.json` credentials and leaves non-OAuth or missing credentials to Pi/provider auth."

Dev: "What should users configure in Lua?"

Domain expert: "Use Agent Configuration for `agent.provider`, `agent.model`, optional `agent.auth`, Agent Options, and Completion Options. Do not expose the old provider adapter shape."

Dev: "Where should annotation wait timing live?"

Domain expert: "Use Annotation Command Configuration under `commands.annotate`; command behavior should not live under Agent Configuration."

Dev: "What should happen if the user does not configure an agent?"

Domain expert: "Use the Default Agent Runtime: Pi targeting `openai/gpt-4o-mini`. The user only needs the corresponding Pi-supported environment credentials."

Dev: "Can users configure a fake runtime?"

Domain expert: "No. Use the Development Agent Runtime only in tests and local harnesses; public configuration should describe real Pi-backed usage."

Dev: "Can the Agent Context File change which Model Target Vantage uses?"

Domain expert: "No. Prompt-Only Context Influence means the file can inform model responses but cannot change Vantage configuration, the Agent Runtime, or the Model Target."

Dev: "What happens if Vantage cannot read the Agent Context File?"

Domain expert: "Use Context Failure Tolerance. Normal commands keep working; Agent Context Status explains what happened."

Dev: "How should fake-runtime tests prove context is wired?"

Domain expert: "Use a Fake Context Signal: show presence and metadata, not the full context content."
