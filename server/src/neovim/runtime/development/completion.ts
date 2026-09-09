import type { CompletionRuntime, CompletionRequest, CompletionResult } from '../completion';

export class DevelopmentCompletionRuntime implements CompletionRuntime {
	async complete(request: CompletionRequest): Promise<CompletionResult> {
		const preview = request.prompt.length > 100 ? request.prompt.slice(0, 100) + '...' : request.prompt;
		return {
			text: `Development completion response for: ${preview}`,
			model: 'development',
			provider: 'development',
		};
	}
}
