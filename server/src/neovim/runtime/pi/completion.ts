import type { CompletionRuntime, CompletionRequest, CompletionResult, CompletionRequestContext } from '../completion';
import type { SimpleStreamOptions } from '@earendil-works/pi-ai';
import type { AgentOptionsConfig } from '../../protocol';
import { createModelTarget } from './model-target';

/**
 * Pi-backed completion runtime: one model call, no tools, no session.
 *
 * Deliberately independent of `PiAgenticRuntime`. They load the same peer
 * dependency -- shared via `pi/model-target` -- but they answer different
 * questions, and nothing here should grow a dependency on agent sessions, tool
 * dispatch, or submission handling. Anything a command needs from a *single*
 * model call belongs on this side of the wall; anything needing tools or
 * iteration belongs on the agentic side.
 */
export interface PiCompletionRuntimeOptions {
	provider: string;
	model: string;
	/** Pi completion options supplied by the user for this runtime. */
	options?: AgentOptionsConfig;
	/** `agent.auth.path` from config. */
	authPath?: string;
}

/** The stop reasons that mean the model finished saying what it meant to say. */
const COMPLETE_STOP_REASONS = new Set(['stop', 'toolUse']);

/**
 * Extracts the text of a finished completion, refusing anything incomplete.
 *
 * Exported so the refusal is testable without a live model. Only `'error'` used
 * to be rejected, so a `'length'` stop -- truncation -- returned its partial
 * text as a normal result. For a file-scope edit that meant the parser saw
 * fewer blocks, applied them, and reported success: a silently partial refactor,
 * which is worse than a failure. `'aborted'` was equally unhandled.
 */
export function textFromMessage(message: {
	stopReason: string;
	errorMessage?: string;
	content: readonly { type: string; text?: string }[];
}): string {
	if (message.stopReason === 'error') {
		throw new Error(message.errorMessage || 'Completion request failed');
	}
	if (!COMPLETE_STOP_REASONS.has(message.stopReason)) {
		throw new Error(`Completion stopped early (${message.stopReason}); the response is incomplete.`);
	}
	return message.content
		.filter((block) => block.type === 'text')
		.map((block) => block.text ?? '')
		.join('');
}

export class PiCompletionRuntime implements CompletionRuntime {
	private readonly provider: string;
	private readonly model: string;
	readonly options: AgentOptionsConfig;
	private readonly authPath?: string;

	constructor(options: PiCompletionRuntimeOptions) {
		this.provider = options.provider;
		this.model = options.model;
		this.options = options.options ?? {};
		this.authPath = options.authPath;
	}

	async complete(request: CompletionRequest, context?: CompletionRequestContext): Promise<CompletionResult> {
		const { modelRuntime, model } = await createModelTarget({
			provider: this.provider,
			model: this.model,
			apiKey: this.options.apiKey,
			authPath: this.authPath,
			// Without this a *relative* agent.auth.path resolved against the
			// backend's cwd here and against the workspace on the agentic path --
			// two different credential files for one config value.
			workspaceRoot: request.workspaceRoot,
		});

		// Abort on timeout. The agentic runtime has always had one; without it a
		// hung provider left the request in flight forever with the client's
		// tracker stuck in `loading` and no notification ever arriving.
		const abort = new AbortController();
		const external = context?.signal;
		if (external) {
			if (external.aborted) {
				abort.abort();
			} else {
				external.addEventListener('abort', () => abort.abort(), { once: true });
			}
		}
		const timeoutMs = this.options.timeoutMs;
		const timer = timeoutMs && timeoutMs > 0 ? setTimeout(() => abort.abort(), timeoutMs) : undefined;

		const messages = [{ role: 'user' as const, content: request.prompt, timestamp: Date.now() }];

		const message = await modelRuntime.completeSimple(
			model,
			{ messages, systemPrompt: request.systemPrompt },
			{
				...this.options,
				signal: abort.signal,
			} satisfies SimpleStreamOptions
		).finally(() => {
			if (timer) {
				clearTimeout(timer);
			}
		});

		const text = textFromMessage(message);

		return {
			text,
			model: this.model,
			provider: this.provider,
			usage: { inputTokens: message.usage.input, outputTokens: message.usage.output },
		};
	}
}
