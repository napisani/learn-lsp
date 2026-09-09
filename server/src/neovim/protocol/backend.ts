import { z } from 'zod';
import type { JsonValue } from '../utils';
import { BackendRequestConfigSchema } from './config';
import {
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
import {
	ExplanationResultSchema,
	AnnotationResultSchema,
	EditResultSchema,
	EditAppliedResultSchema,
	EditHunksResultSchema,
	SearchLocationsResultSchema,
	ListSkillsResultSchema,
	WalkthroughResultSchema,
	CompleteResultSchema,
} from './results';

export const BackendRequestSchema = z.discriminatedUnion('method', [
	z.object({ id: z.string(), method: z.literal('explainSelection'), config: BackendRequestConfigSchema.optional(), params: ExplainSelectionParamsSchema }),
	z.object({ id: z.string(), method: z.literal('questionSelection'), config: BackendRequestConfigSchema.optional(), params: QuestionSelectionParamsSchema }),
	z.object({ id: z.string(), method: z.literal('editSelection'), config: BackendRequestConfigSchema.optional(), params: EditSelectionParamsSchema }),
	z.object({ id: z.string(), method: z.literal('annotateRange'), config: BackendRequestConfigSchema.optional(), params: AnnotateRangeParamsSchema }),
	z.object({ id: z.string(), method: z.literal('searchLocations'), config: BackendRequestConfigSchema.optional(), params: SearchLocationsParamsSchema }),
	z.object({ id: z.string(), method: z.literal('agentCancel'), config: BackendRequestConfigSchema.optional(), params: BaseRequestParamsSchema }),
	z.object({ id: z.string(), method: z.literal('agentSessionReset'), config: BackendRequestConfigSchema.optional(), params: BaseRequestParamsSchema }),
	z.object({ id: z.string(), method: z.literal('agentSessionStatus'), config: BackendRequestConfigSchema.optional(), params: BaseRequestParamsSchema }),
	z.object({ id: z.string(), method: z.literal('agentSessionOutput'), config: BackendRequestConfigSchema.optional(), params: AgentSessionOutputParamsSchema }),
	z.object({ id: z.string(), method: z.literal('listSkills'), config: BackendRequestConfigSchema.optional(), params: BaseRequestParamsSchema }),
	z.object({ id: z.string(), method: z.literal('generateWalkthrough'), config: BackendRequestConfigSchema.optional(), params: GenerateWalkthroughParamsSchema }),
	z.object({ id: z.string(), method: z.literal('complete'), config: BackendRequestConfigSchema.optional(), params: CompleteParamsSchema }),
]);

export const BackendResultSchema = z.discriminatedUnion('kind', [
	ExplanationResultSchema,
	AnnotationResultSchema,
	EditResultSchema,
	EditAppliedResultSchema,
	EditHunksResultSchema,
	SearchLocationsResultSchema,
	ListSkillsResultSchema,
	WalkthroughResultSchema,
	CompleteResultSchema,
]);

export const BackendResponseSchema = z.discriminatedUnion('ok', [
	z.object({ id: z.string(), ok: z.literal(true), result: BackendResultSchema }),
	z.object({ id: z.string(), ok: z.literal(false), error: z.object({ code: z.string(), message: z.string() }) }),
]);

export type BackendMethod = z.infer<typeof BackendRequestSchema>['method'];
export type BackendRequest = z.infer<typeof BackendRequestSchema>;
export type BackendResult = z.infer<typeof BackendResultSchema>;
export type BackendResponse = z.infer<typeof BackendResponseSchema>;

export function parseBackendRequest(value: JsonValue): BackendRequest {
	return BackendRequestSchema.parse(value);
}
