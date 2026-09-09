import { DevelopmentAgentRuntime } from './development/agent';
import { PiAgenticRuntime } from './pi/agent';
import { CodingAgentSessionStore } from './pi/session-store';
import { AdjacentAgentRuntime } from './adjacent/agent';
import type { BackendRequestConfig } from '../protocol';
import type { AgentRuntime } from './agent';

const sessionStore = new CodingAgentSessionStore();
const adjacentStore = new CodingAgentSessionStore();

export function createAgentRuntimeFromConfig(config: BackendRequestConfig = {}): AgentRuntime {
	const agent = config.agent ?? {};
	if (agent.runtime === 'adjacent-or-pi') {
		throw new Error('Resolve adjacent-or-pi before creating the agent runtime.');
	}

	if (agent.runtime === 'development') {
		return new DevelopmentAgentRuntime();
	}

	const options = {
		auth: agent.auth,
		options: agent.options,
		sessionOutput: agent.session_output,
		commandOptions: {
			explain: config.commands?.explain,
			question: config.commands?.question,
			edit: config.commands?.edit,
			annotate: config.commands?.annotate,
			search: config.commands?.search,
			walkthrough: config.commands?.walkthrough,
		},
	};

	if (agent.runtime === 'adjacent') {
		return new AdjacentAgentRuntime({ ...options, store: adjacentStore, socketPath: agent.adjacent?.socket_path });
	}

	return new PiAgenticRuntime({ ...options, provider: agent.provider, model: agent.model, store: sessionStore });
}
