import type { ToolDefinition } from '@earendil-works/pi-coding-agent';
import type { AgentRuntime } from '../agent';
import type { AgentAuthConfig } from '../../protocol';
import { PiAgentCommon, type PiAgentOptions, type PiSessionRequest } from '../pi-agent-common';
import { CodingAgentSessionStore, type AgentSessionHandle, type AgentSessionStore } from '../pi/session-store';
import { forkAdjacentSession, type ForkedSession } from './session';

export interface AdjacentAgentRuntimeOptions extends PiAgentOptions {
	socketPath?: string;
	auth?: AgentAuthConfig;
	forkSession?: (root: string, customTools: ToolDefinition[], tools: string[], signal: AbortSignal, socketPath?: string, auth?: AgentAuthConfig) => Promise<ForkedSession>;
}

/** Owns adjacent-Pi discovery/forking; no fork is retained between requests. */
export class AdjacentAgentRuntime implements AgentRuntime {
	private readonly common: PiAgentCommon;
	private readonly store: AgentSessionStore;
	private readonly forkSession: NonNullable<AdjacentAgentRuntimeOptions['forkSession']>;
	private readonly socketPath?: string;
	private readonly auth?: AgentAuthConfig;
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

	constructor(options: AdjacentAgentRuntimeOptions = {}) {
		this.store = options.store ?? new CodingAgentSessionStore();
		this.forkSession = options.forkSession ?? forkAdjacentSession;
		this.socketPath = options.socketPath;
		this.auth = options.auth;
		this.common = new PiAgentCommon({
			...options,
			provider: 'adjacent',
			model: 'inherited',
			store: this.store,
			statusNote: 'Runtime: adjacent Pi. Each request uses a fresh fork; cancel/reset never changes the parent session.',
			sessions: {
				acquire: (request) => this.acquireSession(request),
				trackRequest: () => true,
				release: (session) => { session?.dispose(); },
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
		const fork: ForkedSession = await this.forkSession(
			request.root, request.customTools, request.activeTools, request.signal, this.socketPath, this.auth,
		);
		this.store.appendOutputEvent?.(request.outputEntryId, {
			type: 'fork_source',
			summary: `Forked Pi ${fork.source.sessionId} at ${fork.source.leafId ?? 'root'} (${fork.source.provider}/${fork.source.model}).${fork.source.parentBusy ? ' Parent busy; using latest completed turn.' : ''}`,
			details: fork.source,
		});
		return fork.session;
	}
}
