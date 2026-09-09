import type { CompletionRuntime } from './completion';
import { PiCompletionRuntime } from './pi/completion';
import { DevelopmentCompletionRuntime } from './development/completion';
import type { BackendRequestConfig } from '../protocol';
import { DEFAULT_PROVIDER, DEFAULT_MODEL } from './pi/defaults';

export function createCompletionRuntimeFromConfig(config: BackendRequestConfig = {}): CompletionRuntime {
	const agent = config.agent ?? {};

	if (agent.runtime === 'development') {
		return new DevelopmentCompletionRuntime();
	}

	return new PiCompletionRuntime({
		provider: agent.provider ?? DEFAULT_PROVIDER,
		model: agent.model ?? DEFAULT_MODEL,
		options: config.completion?.options,
		authPath: agent.auth?.path,
	});
}
