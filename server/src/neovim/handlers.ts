import { Effect } from 'effect';
import * as path from 'node:path';
import { AgentRuntimeSelection } from './runtime/selection';
import type { BackendRequest, BackendResponse, BackendResult } from './protocol';
import { createAgentRuntimeFromConfig } from './runtime/agent-factory';
import { createCompletionRuntimeFromConfig } from './runtime/completion-factory';
import type { AgentRuntime, AgentRuntimeRequestContext } from './runtime/agent';
import { runBackendCommand } from './backend-command';
import { buildExplainPrompt, buildQuestionPrompt, buildAnnotationPrompt, buildEditPrompt, buildFileEditPrompt } from './prompts';
import { parseAnnotationResponse, parseEditResponse, parseSearchReplaceBlocks } from './markdown-utils';
import type { EditHunk, EditScope, EditSelectionParams } from './protocol';
import {
	BackendCommandExecutionError,
	BackendRuntimeConfigurationError,
	errorMessage,
} from './effect-errors';

const runtimeSelection = new AgentRuntimeSelection();

// Methods that can run through CompletionRuntime instead of the full agent
// runtime when the caller sets params.runtime === 'completion'. 'complete'
// itself is unconditionally completion-only (see below) and isn't in this
// set since it's never dispatched through the agent-runtime path at all.
const COMPLETION_ELIGIBLE_METHODS = new Set<BackendRequest['method']>([
	'explainSelection',
	'questionSelection',
	'annotateRange',
	'editSelection',
]);

function usesCompletionRuntime(request: BackendRequest): boolean {
	if (request.method === 'complete') {
		return true;
	}
	return COMPLETION_ELIGIBLE_METHODS.has(request.method) && 'runtime' in request.params && request.params.runtime === 'completion';
}

export function handleBackendRequestEffect(
	request: BackendRequest,
	agentRuntime: AgentRuntime | undefined = undefined,
	context: AgentRuntimeRequestContext = {}
): Effect.Effect<BackendResponse> {
	return Effect.gen(function* () {
		yield* reportProgressEffect(context, {
			stage: 'backend_received',
			message: `Backend received ${request.method}.`,
			details: { method: request.method },
		});

		// Completion mode is independent of the agent conversation source. In
		// particular, adjacent-or-pi discovery must not make a one-shot completion
		// depend on a healthy or unambiguous adjacent bridge.
		if (usesCompletionRuntime(request)) {
			const result = yield* runCompletionEffect(request, context);
			return { id: request.id, ok: true, result } satisfies BackendResponse;
		}

		const config = agentRuntime ? request.config : yield* resolveRuntimeConfigEffect(request, context);
		const activeRequest = { ...request, config };
		const activeRuntime = yield* createRuntimeEffect(activeRequest, agentRuntime);
		yield* reportProgressEffect(context, {
			stage: 'runtime_ready',
			message: 'Agent runtime is ready.',
			details: runtimeDetails(activeRequest),
		});
		const result = yield* runCommandEffect(activeRuntime, activeRequest, context);
		return { id: request.id, ok: true, result } satisfies BackendResponse;
	}).pipe(
		Effect.catchAll((error) => Effect.succeed(handlerErrorResponse(request.id, error))),
		Effect.catchAllDefect((defect) => Effect.succeed(handlerErrorResponse(request.id, defect)))
	);
}

export async function handleBackendRequest(
	request: BackendRequest,
	agentRuntime: AgentRuntime | undefined = undefined,
	context: AgentRuntimeRequestContext = {}
): Promise<BackendResponse> {
	return Effect.runPromise(handleBackendRequestEffect(request, agentRuntime, context));
}

function resolveRuntimeConfigEffect(request: BackendRequest, context: AgentRuntimeRequestContext) {
	return Effect.tryPromise({
		try: () => {
			const params = request.params;
			const root = params.workspaceRoot?.trim() || ('filePath' in params ? path.dirname(params.filePath) : process.cwd());
			return runtimeSelection.resolve(request.config ?? {}, root, context.signal);
		},
		catch: (cause) => new BackendRuntimeConfigurationError({ message: errorMessage(cause), cause }),
	});
}

function createRuntimeEffect(
	request: BackendRequest,
	agentRuntime: AgentRuntime | undefined
): Effect.Effect<AgentRuntime, BackendRuntimeConfigurationError> {
	return Effect.try({
		try: () => agentRuntime ?? createAgentRuntimeFromConfig(request.config),
		catch: (cause) => new BackendRuntimeConfigurationError({
			message: errorMessage(cause),
			cause,
		}),
	});
}

function runCommandEffect(
	runtime: AgentRuntime,
	request: BackendRequest,
	context: AgentRuntimeRequestContext
): Effect.Effect<BackendResult, BackendCommandExecutionError> {
	return Effect.tryPromise({
		try: () => Promise.resolve(runBackendCommand(runtime, request, context)),
		catch: (cause) => new BackendCommandExecutionError({
			method: request.method,
			message: errorMessage(cause),
			cause,
		}),
	});
}

// Owner contract for what a completion-eligible method needs to hand
// CompletionRuntime.complete() -- named so its return position keeps type
// evidence instead of widening to an anonymous shape.
interface CompletionPrompt {
	prompt: string;
	systemPrompt?: string;
}

// Builds the completion prompt for a completion-eligible method. 'complete'
// takes its prompt directly from params; the others reuse the same
// agent-decoupled prompt builders runtime/pi/agent.ts already calls before handing
// the prompt to the agent, so completion mode produces the same prompt an
// agent-mode request would, using the completion-specific output format where
// needed.
function completionPromptFor(request: BackendRequest): CompletionPrompt {
	switch (request.method) {
		case 'complete':
			return { prompt: request.params.prompt, systemPrompt: request.params.systemPrompt } satisfies CompletionPrompt;
		case 'explainSelection':
			return { prompt: buildExplainPrompt(request.params) } satisfies CompletionPrompt;
		case 'questionSelection':
			return { prompt: buildQuestionPrompt(request.params) } satisfies CompletionPrompt;
		case 'annotateRange':
			// buildAnnotationPrompt already tells the model "if submit_annotations
			// is unavailable, return only JSON" -- no completion-specific prompt
			// variant needed.
			return { prompt: buildAnnotationPrompt(request.params) } satisfies CompletionPrompt;
		case 'editSelection':
			// Scope picks the prompt and the result shape together; both come from
			// one descriptor so the pairing cannot drift apart.
			return { prompt: editScope(request.params.scope).buildPrompt(request.params) } satisfies CompletionPrompt;
		default:
			throw new Error(`${request.method} is not eligible for CompletionRuntime`);
	}
}

/**
 * What an edit scope asks the model for, and how its answer is read back.
 *
 * One record per scope rather than a `scope === 'file'` test in each of the two
 * switches: the prompt and the result shape are a single decision, and stating
 * it twice is how the two drift apart.
 */
interface EditScopeHandler {
	buildPrompt: (params: EditSelectionParams) => string;
	buildResult: (text: string, filePath: string) => BackendResult;
}

const EDIT_SCOPES = {
	selection: {
		buildPrompt: (params) => buildEditPrompt(params),
		buildResult: (text) => ({ kind: 'edit', replacementText: parseEditResponse(text) }),
	},
	file: {
		buildPrompt: (params) => buildFileEditPrompt(params),
		buildResult: (text, filePath) => ({
			kind: 'edits',
			hunks: hunksForCurrentFile(parseSearchReplaceBlocks(text), filePath),
		}),
	},
} satisfies Record<EditScope, EditScopeHandler>;

/** Omitted scope means 'selection', so existing callers are unaffected. */
function editScope(scope: EditScope | undefined): EditScopeHandler {
	return EDIT_SCOPES[scope ?? 'selection'];
}

/**
 * Drops blocks that name a file other than the one being edited.
 *
 * The prompt asks the model to edit only the current file, but a prompt is a
 * request to untrusted output, not a check on it. Without this, a block headed
 * `other/module.lua` whose SEARCH text also occurred in the open buffer was
 * spliced into that buffer and reported as a successful edit -- while the README
 * promised such blocks were rejected. A block with no filename is kept: the
 * header is optional decoration, and its absence is not a claim about another
 * file.
 */
export function hunksForCurrentFile(hunks: EditHunk[], filePath: string): EditHunk[] {
	return hunks.filter((hunk) => {
		if (!hunk.filePath) {
			return true;
		}
		// Compare by suffix: the model writes repo-relative paths, the request
		// carries an absolute one.
		const named = hunk.filePath.replace(/^\.\//, '');
		return filePath === named || filePath.endsWith(`/${named}`);
	});
}

// Owns turning CompletionRuntime's raw text back into the exact
// BackendResult the client already expects for this method, so
// vantage.model_command / vantage.annotation_command don't need to know
// which runtime actually served the request.
function completionResultFor(request: BackendRequest, text: string): BackendResult {
	switch (request.method) {
		case 'explainSelection':
		case 'questionSelection':
			return { kind: 'explanation', markdown: text };
		case 'annotateRange':
			// Reuses the same annotation-shape parser/validation the
			// submit_annotations tool-call path already goes through
			// (parseAnnotationPayload) -- this one just also handles pulling the
			// annotations array out of the model's raw JSON text first, since
			// there's no tool call to extract it from in completion mode.
			return { kind: 'annotations', annotations: parseAnnotationResponse(text, 0, 'completion', request.params.candidateLines ?? []) };
		case 'editSelection':
			return editScope(request.params.scope).buildResult(text, request.params.filePath);
		case 'complete':
			return { kind: 'completion', text };
		default:
			throw new Error(`${request.method} is not eligible for CompletionRuntime`);
	}
}

function runCompletionEffect(
	request: BackendRequest,
	context: AgentRuntimeRequestContext
): Effect.Effect<BackendResult, BackendCommandExecutionError> {
	return Effect.tryPromise({
		try: async () => {
			const runtime = createCompletionRuntimeFromConfig(request.config);
			const { prompt, systemPrompt } = completionPromptFor(request);
			const result = await runtime.complete(
				{
					prompt,
					systemPrompt,
					workspaceRoot: 'workspaceRoot' in request.params ? request.params.workspaceRoot : undefined,
				},
				{ signal: context.signal }
			);
			return completionResultFor(request, result.text);
		},
		catch: (cause) => new BackendCommandExecutionError({
			method: request.method,
			message: errorMessage(cause),
			cause,
		}),
	});
}

function reportProgressEffect(
	context: AgentRuntimeRequestContext,
	progress: Parameters<NonNullable<AgentRuntimeRequestContext['reportProgress']>>[0]
): Effect.Effect<void> {
	return Effect.sync(() => {
		context.reportProgress?.(progress);
	});
}

function handlerErrorResponse(id: string, cause: unknown): BackendResponse {
	return {
		id,
		ok: false,
		error: {
			code: 'handler_error',
			message: errorMessage(cause),
		},
	};
}

function runtimeDetails(request: BackendRequest) {
	const agent = request.config?.agent ?? {};
	return {
		runtime: agent.runtime ?? 'pi',
		provider: agent.provider,
		model: agent.model,
	};
}
