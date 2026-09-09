// Primitives
export { LensModeSchema, AgentRuntimeNameSchema, AgentReasoningLevelSchema, CoordinateSchema } from './primitives';
export type { LensMode, AgentRuntimeName, AgentReasoningLevel } from './primitives';

// Domain values
export { LensSchema, PositionSchema, RangeSchema, AnnotationCandidateLineSchema, GitContextSchema, AgentContextSchema } from './domain';
export type { Lens, Position, Range, AnnotationCandidateLine, GitContext, AgentContext } from './domain';

// Config
export {
	AgentOptionsConfigSchema,
	AgentAuthConfigSchema,
	AgentSessionOutputConfigSchema,
	AgentRuntimeConfigSchema,
	CompletionRuntimeConfigSchema,
	CommandConfigSchema,
	AnnotateCommandConfigSchema,
	CommandsConfigSchema,
	BackendRequestConfigSchema,
} from './config';
export type {
	AgentOptionsConfig,
	AgentAuthConfig,
	AgentSessionOutputConfig,
	AgentRuntimeConfig,
	CompletionRuntimeConfig,
	CommandConfig,
	SearchCommandConfig,
	AnnotateCommandConfig,
	CommandsConfig,
	BackendRequestConfig,
} from './config';

// Request params
export {
	RuntimeSchema,
	BaseRequestParamsSchema,
	ExplainSelectionParamsSchema,
	QuestionSelectionParamsSchema,
	EditSelectionParamsSchema,
	AnnotateRangeParamsSchema,
	SearchLocationsParamsSchema,
	GenerateWalkthroughParamsSchema,
	AgentSessionOutputParamsSchema,
	CompleteParamsSchema,
} from './params';
export type {
	Runtime,
	EditScope,
	BaseRequestParams,
	ExplainSelectionParams,
	QuestionSelectionParams,
	EditSelectionParams,
	AnnotateRangeParams,
	SearchLocationsParams,
	GenerateWalkthroughParams,
	AgentSessionOutputParams,
	CompleteParams,
} from './params';

// Results
export {
	AgentRuntimeTelemetrySchema,
	ExplanationResultSchema,
	AnnotationSchema,
	AnnotationResultSchema,
	EditResultSchema,
	EditAppliedResultSchema,
	EditHunkSchema,
	EditHunksResultSchema,
	SearchLocationSchema,
	SearchLocationsResultSchema,
	SkillSummarySchema,
	SkillDiagnosticSummarySchema,
	ListSkillsResultSchema,
	WalkthroughPointerSchema,
	WalkthroughResultSchema,
	CompleteResultSchema,
	AgentRuntimeProgressSchema,
} from './results';
export type {
	AgentRuntimeTelemetry,
	ExplanationResult,
	Annotation,
	AnnotationResult,
	EditResult,
	EditAppliedResult,
	EditHunk,
	EditHunksResult,
	SearchLocation,
	SearchLocationsResult,
	SkillSummary,
	SkillDiagnosticSummary,
	ListSkillsResult,
	WalkthroughPointer,
	WalkthroughResult,
	CompleteResult,
	AgentRuntimeProgress,
} from './results';

// Backend request/response
export { BackendRequestSchema, BackendResultSchema, BackendResponseSchema, parseBackendRequest } from './backend';
export type { BackendMethod, BackendRequest, BackendResult, BackendResponse } from './backend';
