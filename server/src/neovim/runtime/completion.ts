export interface CompletionRequest {
	prompt: string;
	systemPrompt?: string;
	/** Base for resolving a relative `agent.auth.path`. */
	workspaceRoot?: string;
}

export interface CompletionResult {
	text: string;
	model?: string;
	provider?: string;
	usage?: {
		inputTokens: number;
		outputTokens: number;
	};
}

export interface CompletionRequestContext {
	signal?: AbortSignal;
}

export interface CompletionRuntime {
	complete(request: CompletionRequest, context?: CompletionRequestContext): Promise<CompletionResult>;
}
