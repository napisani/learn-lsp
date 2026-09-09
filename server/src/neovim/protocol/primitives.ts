import { z } from 'zod';

export const LensModeSchema = z.enum(['learning', 'review', 'general']);
export const AgentRuntimeNameSchema = z.enum(['pi', 'adjacent', 'adjacent-or-pi', 'development']);
export const AgentReasoningLevelSchema = z.enum(['minimal', 'low', 'medium', 'high', 'xhigh']);
export const CoordinateSchema = z.number().int().min(1);

export type LensMode = z.infer<typeof LensModeSchema>;
export type AgentRuntimeName = z.infer<typeof AgentRuntimeNameSchema>;
export type AgentReasoningLevel = z.infer<typeof AgentReasoningLevelSchema>;
