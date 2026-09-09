import { z } from 'zod';
import { LensSchema, PositionSchema, RangeSchema, GitContextSchema, AgentContextSchema, AnnotationCandidateLineSchema } from './domain';

export const BaseRequestParamsSchema = z.object({
	workspaceRoot: z.string().optional(),
	filePath: z.string(),
	language: z.string(),
	text: z.string(),
	cursor: PositionSchema,
	lens: LensSchema.optional(),
	git: GitContextSchema.optional(),
	agentContext: AgentContextSchema.optional(),
});

// 'agent' (default) runs the full tool-using agent session; 'completion' runs
// a single one-shot completion call with no tools/session.
export const RuntimeSchema = z.enum(['agent', 'completion']);

// Named and exported like RuntimeSchema, so consumers reference the concept
// instead of hand-typing 'file' at every branch.
export const EditScopeSchema = z.enum(['selection', 'file']);

export const ExplainSelectionParamsSchema = BaseRequestParamsSchema.extend({
	selectedText: z.string(),
	runtime: RuntimeSchema.optional(),
});

export const QuestionSelectionParamsSchema = BaseRequestParamsSchema.extend({
	selectedText: z.string(),
	question: z.string().min(1),
	runtime: RuntimeSchema.optional(),
});

// For completion runtime, `scope` decides both what the model is asked for and
// what it returns. 'selection' asks for replacement text over `range`; 'file'
// asks for SEARCH/REPLACE blocks and carries the whole buffer in `scopeText` so
// the model can author anchors against the text it must match. Agent runtime
// treats the context as a starting hint and lets Pi own the edit scope.
export const EditSelectionParamsSchema = BaseRequestParamsSchema.extend({
	range: RangeSchema,
	// `scopeText`, not `selectedText`: under file scope this holds the entire
	// buffer, so the old name described only half its uses -- and the prompt had
	// to relabel it "Current file contents:" to stay honest.
	// AnnotateRangeParams already uses `scopeText` for exactly this role.
	scopeText: z.string(),
	instruction: z.string().min(1),
	runtime: RuntimeSchema.optional(),
	scope: EditScopeSchema.optional(),
});

export const AnnotateRangeParamsSchema = BaseRequestParamsSchema.extend({
	visibleRange: RangeSchema.optional(),
	range: RangeSchema.optional(),
	scopeText: z.string(),
	maxAnnotations: z.number().int().positive().optional(),
	candidateLines: z.array(AnnotationCandidateLineSchema).optional(),
	runtime: RuntimeSchema.optional(),
});

export const SearchLocationsParamsSchema = BaseRequestParamsSchema.extend({
	query: z.string().min(1),
	selectedText: z.string().optional(),
	range: RangeSchema.optional(),
});

export const GenerateWalkthroughParamsSchema = BaseRequestParamsSchema.extend({
	prompt: z.string().min(1),
});

export const AgentSessionOutputParamsSchema = BaseRequestParamsSchema.extend({
	raw: z.boolean().optional(),
});

export const CompleteParamsSchema = BaseRequestParamsSchema.extend({
	prompt: z.string().min(1),
	systemPrompt: z.string().optional(),
});

export type Runtime = z.infer<typeof RuntimeSchema>;
export type EditScope = z.infer<typeof EditScopeSchema>;
export type BaseRequestParams = z.infer<typeof BaseRequestParamsSchema>;
export type ExplainSelectionParams = z.infer<typeof ExplainSelectionParamsSchema>;
export type QuestionSelectionParams = z.infer<typeof QuestionSelectionParamsSchema>;
export type EditSelectionParams = z.infer<typeof EditSelectionParamsSchema>;
export type AnnotateRangeParams = z.infer<typeof AnnotateRangeParamsSchema>;
export type SearchLocationsParams = z.infer<typeof SearchLocationsParamsSchema>;
export type GenerateWalkthroughParams = z.infer<typeof GenerateWalkthroughParamsSchema>;
export type AgentSessionOutputParams = z.infer<typeof AgentSessionOutputParamsSchema>;
export type CompleteParams = z.infer<typeof CompleteParamsSchema>;
