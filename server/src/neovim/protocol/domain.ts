import { z } from 'zod';
import { LensModeSchema, CoordinateSchema } from './primitives';

export const LensSchema = z.object({
	mode: LensModeSchema,
	text: z.string().optional(),
});

export const PositionSchema = z.object({
	line: CoordinateSchema,
	character: CoordinateSchema,
});

export const RangeSchema = z.object({
	startLine: CoordinateSchema,
	startCharacter: CoordinateSchema,
	endLine: CoordinateSchema,
	endCharacter: CoordinateSchema,
});

export const AnnotationCandidateLineSchema = z.object({
	line: CoordinateSchema,
	text: z.string(),
});

export const GitContextSchema = z.object({
	branch: z.string().optional(),
	repositoryRoot: z.string().optional(),
	currentHunk: z.string().optional(),
	touchedFiles: z.array(z.string()).optional(),
});

export const AgentContextSchema = z.object({
	path: z.string(),
	content: z.string(),
	revision: z.string().optional(),
	modifiedAt: z.string().optional(),
	ageMs: z.number().nonnegative().optional(),
	truncated: z.boolean(),
});

export type Lens = z.infer<typeof LensSchema>;
export type Position = z.infer<typeof PositionSchema>;
export type Range = z.infer<typeof RangeSchema>;
export type AnnotationCandidateLine = z.infer<typeof AnnotationCandidateLineSchema>;
export type GitContext = z.infer<typeof GitContextSchema>;
export type AgentContext = z.infer<typeof AgentContextSchema>;
