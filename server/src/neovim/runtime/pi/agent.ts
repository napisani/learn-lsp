import type { ToolDefinition } from '@earendil-works/pi-coding-agent';
import type { AgentRuntime } from '../agent';
import type { AgentAuthConfig } from '../../protocol';
import { PiAgentCommon, type PiAgentOptions, type PiSessionRequest } from '../pi-agent-common';
import { CodingAgentSessionStore, type AgentSessionHandle, type AgentSessionStore } from './session-store';
import { createModelTarget } from './model-target';
import { DEFAULT_PROVIDER, DEFAULT_MODEL } from './defaults';

export { CodingAgentSessionStore } from './session-store';
export { codingAgentErrorMessage, loadCodingAgentModuleForTest } from '../pi-agent-common';

export interface PiAgenticRuntimeOptions extends PiAgentOptions {
	provider?: string;
	model?: string;
	auth?: AgentAuthConfig;
}

/** Owns the persistent Pi buddy session and transient annotation sessions. */
export class PiAgenticRuntime implements AgentRuntime {
	readonly provider: string;
	readonly model: string;
	readonly auth?: AgentAuthConfig;
	readonly options: PiAgentCommon['options'];
	readonly commandOptions: PiAgentCommon['commandOptions'];
	private readonly store: AgentSessionStore;
	private readonly common: PiAgentCommon;
	readonly explainSelection: PiAgentCommon['explainSelection'];
	readonly questionSelection: PiAgentCommon['questionSelection'];
	readonly editSelection: PiAgentCommon['editSelection'];
	readonly annotateRange: PiAgentCommon['annotateRange'];
	readonly searchLocations: PiAgentCommon['searchLocations'];
	readonly generateWalkthrough: PiAgentCommon['generateWalkthrough'];
	readonly agentCancel: PiAgentCommon['agentCancel'];
	readonly agentSessionReset: PiAgentCommon['agentSessionReset'];
	readonly agentSessionStatus: PiAgentCommon['agentSessionStatus'];
	readonly agentSessionOutput: PiAgentCommon['agentSessionOutput'];
	readonly listSkills: PiAgentCommon['listSkills'];
	readonly submissionTools: PiAgentCommon['submissionTools'];

	constructor(options: PiAgenticRuntimeOptions = {}) {
		this.provider = options.provider ?? DEFAULT_PROVIDER;
		this.model = options.model ?? DEFAULT_MODEL;
		this.auth = options.auth;
		this.options = options.options ?? {};
		this.commandOptions = options.commandOptions ?? {};
		this.store = options.store ?? new CodingAgentSessionStore();
		this.common = new PiAgentCommon({
			...options,
			provider: this.provider,
			model: this.model,
			store: this.store,
			sessions: {
				acquire: (request) => this.acquireSession(request),
				trackRequest: (transient) => !transient,
				release: (session, transient) => {
					if (transient) {
						session?.dispose();
					}
				},
			},
		});
		this.explainSelection = this.common.explainSelection.bind(this.common);
		this.questionSelection = this.common.questionSelection.bind(this.common);
		this.editSelection = this.common.editSelection.bind(this.common);
		this.annotateRange = this.common.annotateRange.bind(this.common);
		this.searchLocations = this.common.searchLocations.bind(this.common);
		this.generateWalkthrough = this.common.generateWalkthrough.bind(this.common);
		this.agentCancel = this.common.agentCancel.bind(this.common);
		this.agentSessionReset = this.common.agentSessionReset.bind(this.common);
		this.agentSessionStatus = this.common.agentSessionStatus.bind(this.common);
		this.agentSessionOutput = this.common.agentSessionOutput.bind(this.common);
		this.listSkills = this.common.listSkills.bind(this.common);
		this.submissionTools = this.common.submissionTools.bind(this.common);
	}

	private async acquireSession(request: PiSessionRequest): Promise<AgentSessionHandle> {
		const { root, customTools, transient } = request;
		if (transient) {
			return this.createSession(root, customTools, ['submit_annotations']);
		}
		return this.store.getOrCreate({
			workspaceRoot: root,
			provider: this.provider,
			model: this.model,
			createSession: () => this.createSession(root, customTools, [
				'read', 'grep', 'find', 'ls', 'edit', 'write',
				'submit_search_results', 'submit_annotations', 'submit_walkthrough',
			]),
		});
	}

	private async createSession(root: string, customTools: ToolDefinition[], tools: string[]): Promise<AgentSessionHandle> {
		const { piAgent, modelRuntime, model } = await createModelTarget({
			provider: this.provider,
			model: this.model,
			apiKey: this.options.apiKey,
			authPath: this.auth?.path,
			workspaceRoot: root,
		});
		const { session } = await piAgent.createAgentSession({
			cwd: root,
			modelRuntime,
			model,
			thinkingLevel: this.options.reasoning,
			tools,
			customTools,
			sessionManager: piAgent.SessionManager.inMemory(root),
		});
		return session;
	}
}
