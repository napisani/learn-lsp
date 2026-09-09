import type {
	AnnotateRangeParams,
	AnnotationResult,
	BaseRequestParams,
	EditAppliedResult,
	EditResult,
	EditSelectionParams,
	ExplainSelectionParams,
	ExplanationResult,
	GenerateWalkthroughParams,
	QuestionSelectionParams,
	SearchLocationsParams,
	SearchLocationsResult,
	AgentRuntimeProgress,
	AgentSessionOutputParams,
	ListSkillsResult,
	WalkthroughResult,
} from '../protocol';

export type AgentRuntimeResult<T> = T | Promise<T>;

export interface AgentRuntimeRequestContext {
	signal?: AbortSignal;
	reportProgress?: (progress: AgentRuntimeProgress) => void;
}

export interface AgentRuntime {
	explainSelection(params: ExplainSelectionParams, context?: AgentRuntimeRequestContext): AgentRuntimeResult<ExplanationResult>;
	questionSelection(params: QuestionSelectionParams, context?: AgentRuntimeRequestContext): AgentRuntimeResult<ExplanationResult>;
	editSelection(params: EditSelectionParams, context?: AgentRuntimeRequestContext): AgentRuntimeResult<EditResult | EditAppliedResult>;
	annotateRange(params: AnnotateRangeParams, context?: AgentRuntimeRequestContext): AgentRuntimeResult<AnnotationResult>;
	searchLocations(params: SearchLocationsParams, context?: AgentRuntimeRequestContext): AgentRuntimeResult<SearchLocationsResult>;
	agentCancel(params: BaseRequestParams, context?: AgentRuntimeRequestContext): AgentRuntimeResult<ExplanationResult>;
	agentSessionReset(params: BaseRequestParams, context?: AgentRuntimeRequestContext): AgentRuntimeResult<ExplanationResult>;
	agentSessionStatus(params: BaseRequestParams, context?: AgentRuntimeRequestContext): AgentRuntimeResult<ExplanationResult>;
	agentSessionOutput(params: AgentSessionOutputParams, context?: AgentRuntimeRequestContext): AgentRuntimeResult<ExplanationResult>;
	listSkills(params: BaseRequestParams, context?: AgentRuntimeRequestContext): AgentRuntimeResult<ListSkillsResult>;
	generateWalkthrough(params: GenerateWalkthroughParams, context?: AgentRuntimeRequestContext): AgentRuntimeResult<WalkthroughResult>;
}
