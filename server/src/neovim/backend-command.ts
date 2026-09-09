import type { AgentRuntime, AgentRuntimeRequestContext } from './runtime/agent';
import type { BackendMethod, BackendRequest, BackendResult } from './protocol';

export const BACKEND_METHODS = [
	'explainSelection',
	'questionSelection',
	'editSelection',
	'annotateRange',
	'searchLocations',
	'agentCancel',
	'agentSessionReset',
	'agentSessionStatus',
	'agentSessionOutput',
	'listSkills',
	'generateWalkthrough',
	'complete',
] as const;

type CommandHandlerMap = {
	[Method in BackendMethod]: (
		runtime: AgentRuntime,
		request: Extract<BackendRequest, { method: Method }>,
		context: AgentRuntimeRequestContext
	) => Promise<BackendResult> | BackendResult;
};

const commandHandlers: CommandHandlerMap = {
	explainSelection: (runtime, request, ctx) => runtime.explainSelection(request.params, ctx),
	questionSelection: (runtime, request, ctx) => runtime.questionSelection(request.params, ctx),
	editSelection: (runtime, request, ctx) => runtime.editSelection(request.params, ctx),
	annotateRange: (runtime, request, ctx) => runtime.annotateRange(request.params, ctx),
	searchLocations: (runtime, request, ctx) => runtime.searchLocations(request.params, ctx),
	agentCancel: (runtime, request, ctx) => runtime.agentCancel(request.params, ctx),
	agentSessionReset: (runtime, request, ctx) => runtime.agentSessionReset(request.params, ctx),
	agentSessionStatus: (runtime, request, ctx) => runtime.agentSessionStatus(request.params, ctx),
	agentSessionOutput: (runtime, request, ctx) => runtime.agentSessionOutput(request.params, ctx),
	listSkills: (runtime, request, ctx) => runtime.listSkills(request.params, ctx),
	generateWalkthrough: (runtime, request, ctx) => runtime.generateWalkthrough(request.params, ctx),
	complete: () => {
		throw new Error('complete is dispatched through CompletionRuntime, not runBackendCommand');
	},
};

export function runBackendCommand(
	runtime: AgentRuntime,
	request: BackendRequest,
	context: AgentRuntimeRequestContext
): Promise<BackendResult> | BackendResult {
	return dispatchCommand(runtime, request, context);
}

function dispatchCommand<M extends BackendMethod>(
	runtime: AgentRuntime,
	request: Extract<BackendRequest, { method: M }>,
	context: AgentRuntimeRequestContext
): Promise<BackendResult> | BackendResult {
	return commandHandlers[request.method](runtime, request, context);
}
