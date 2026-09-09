import { z } from 'zod';
import { CoordinateSchema } from './primitives';
import { RangeSchema } from './domain';

export const AgentRuntimeTelemetrySchema = z.object({
	runtime: z.string(),
	model: z.string().optional(),
	promptChars: z.number().optional(),
	promptLines: z.number().optional(),
	elapsedMs: z.number().optional(),
	totalDurationMs: z.number().optional(),
	promptEvalCount: z.number().optional(),
	evalCount: z.number().optional(),
});

export const ExplanationResultSchema = z.object({
	kind: z.literal('explanation'),
	markdown: z.string(),
});

export const AnnotationSchema = z.object({
	range: RangeSchema,
	text: z.string(),
	severity: z.enum(['info', 'warning']),
	detailMarkdown: z.string().optional(),
});

export const AnnotationResultSchema = z.object({
	kind: z.literal('annotations'),
	annotations: z.array(AnnotationSchema),
	telemetry: AgentRuntimeTelemetrySchema.optional(),
});

export const EditResultSchema = z.object({
	kind: z.literal('edit'),
	replacementText: z.string(),
	telemetry: AgentRuntimeTelemetrySchema.optional(),
});

// Agent-runtime edits are applied by Pi's native edit/write tools. The client
// receives only an acknowledgement; it must not apply replacement text itself.
export const EditAppliedResultSchema = z.object({
	kind: z.literal('edit_applied'),
	summary: z.string(),
});

// The file-scope counterpart to EditResultSchema. Two result kinds rather than
// one polymorphic shape, so the kind alone tells the client which apply path to
// take -- mirroring how 'annotations' and 'locations' already discriminate.
export const EditHunkSchema = z.object({
	search: z.string(),
	replace: z.string(),
	// Path the model wrote above the block, when it supplied one. Carried rather
	// than dropped so a block naming a different file can actually be rejected --
	// the guarantee the README states.
	filePath: z.string().optional(),
});

export const EditHunksResultSchema = z.object({
	kind: z.literal('edits'),
	hunks: z.array(EditHunkSchema),
	telemetry: AgentRuntimeTelemetrySchema.optional(),
});

export const SearchLocationSchema = z.object({
	filePath: z.string(),
	startLine: CoordinateSchema,
	startCharacter: CoordinateSchema,
	lineCount: z.number().optional(),
	explanation: z.string(),
});

export const SearchLocationsResultSchema = z.object({
	kind: z.literal('locations'),
	locations: z.array(SearchLocationSchema),
	telemetry: AgentRuntimeTelemetrySchema.optional(),
});

export const SkillSummarySchema = z.object({
	name: z.string(),
	description: z.string(),
	filePath: z.string(),
	source: z.string().optional(),
});

export const SkillDiagnosticSummarySchema = z.object({
	message: z.string(),
	severity: z.string().optional(),
});

export const ListSkillsResultSchema = z.object({
	kind: z.literal('skills'),
	skills: z.array(SkillSummarySchema),
	diagnostics: z.array(SkillDiagnosticSummarySchema).optional(),
});

export const WalkthroughPointerSchema = z.object({
	file: z.string(),
	line: CoordinateSchema,
	anchor: z.string().optional(),
	description: z.string(),
});

export const WalkthroughResultSchema = z.object({
	kind: z.literal('walkthrough'),
	path: z.string(),
	pointerCount: z.number(),
});

export const CompleteResultSchema = z.object({
	kind: z.literal('completion'),
	text: z.string(),
});

export const AgentRuntimeProgressSchema = z.object({
	stage: z.string(),
	message: z.string().optional(),
	details: z.record(z.string(), z.unknown()).optional(),
});

export type AgentRuntimeTelemetry = z.infer<typeof AgentRuntimeTelemetrySchema>;
export type ExplanationResult = z.infer<typeof ExplanationResultSchema>;
export type Annotation = z.infer<typeof AnnotationSchema>;
export type AnnotationResult = z.infer<typeof AnnotationResultSchema>;
export type EditResult = z.infer<typeof EditResultSchema>;
export type EditAppliedResult = z.infer<typeof EditAppliedResultSchema>;
export type EditHunk = z.infer<typeof EditHunkSchema>;
export type EditHunksResult = z.infer<typeof EditHunksResultSchema>;
export type SearchLocation = z.infer<typeof SearchLocationSchema>;
export type SearchLocationsResult = z.infer<typeof SearchLocationsResultSchema>;
export type SkillSummary = z.infer<typeof SkillSummarySchema>;
export type SkillDiagnosticSummary = z.infer<typeof SkillDiagnosticSummarySchema>;
export type ListSkillsResult = z.infer<typeof ListSkillsResultSchema>;
export type WalkthroughPointer = z.infer<typeof WalkthroughPointerSchema>;
export type WalkthroughResult = z.infer<typeof WalkthroughResultSchema>;
export type CompleteResult = z.infer<typeof CompleteResultSchema>;
export type AgentRuntimeProgress = z.infer<typeof AgentRuntimeProgressSchema>;
