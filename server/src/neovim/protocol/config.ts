import { z } from 'zod';
import { AgentRuntimeNameSchema, AgentReasoningLevelSchema } from './primitives';

export const AgentOptionsConfigSchema = z.object({
	apiKey: z.string().optional(),
	temperature: z.number().nonnegative().optional(),
	maxTokens: z.number().int().positive().optional(),
	timeoutMs: z.number().int().positive().optional(),
	maxRetries: z.number().int().nonnegative().optional(),
	maxRetryDelayMs: z.number().int().nonnegative().optional(),
	reasoning: AgentReasoningLevelSchema.optional(),
	metadata: z.record(z.string(), z.unknown()).optional(),
	headers: z.record(z.string(), z.string()).optional(),
}).catchall(z.unknown());

export type AgentOptionsConfig = z.infer<typeof AgentOptionsConfigSchema>;

export const AgentAuthConfigSchema = z.object({
	path: z.string().optional(),
});

export const AgentSessionOutputConfigSchema = z.object({
	history_limit: z.number().int().nonnegative().optional(),
});

export const AgentRuntimeConfigSchema = z.object({
	runtime: AgentRuntimeNameSchema.optional(),
	adjacent: z.object({ socket_path: z.string().min(1).optional() }).optional(),
	provider: z.string().optional(),
	model: z.string().optional(),
	auth: AgentAuthConfigSchema.optional(),
	options: AgentOptionsConfigSchema.optional(),
	session_output: AgentSessionOutputConfigSchema.optional(),
});

export const CommandConfigSchema = z.object({
	include_lens: z.boolean().optional(),
	options: AgentOptionsConfigSchema.optional(),
});

export const AnnotateCommandConfigSchema = CommandConfigSchema.extend({
	waiting_message_ms: z.number().int().nonnegative().optional(),
});

export const CommandsConfigSchema = z.object({
	explain: CommandConfigSchema.optional(),
	question: CommandConfigSchema.optional(),
	edit: CommandConfigSchema.optional(),
	annotate: AnnotateCommandConfigSchema.optional(),
	search: CommandConfigSchema.optional(),
	walkthrough: CommandConfigSchema.optional(),
});

export const CompletionRuntimeConfigSchema = z.object({
	options: AgentOptionsConfigSchema.optional(),
});

export const BackendRequestConfigSchema = z.object({
	agent: AgentRuntimeConfigSchema.optional(),
	completion: CompletionRuntimeConfigSchema.optional(),
	commands: CommandsConfigSchema.optional(),
});

export type CompletionRuntimeConfig = z.infer<typeof CompletionRuntimeConfigSchema>;
export type AgentAuthConfig = z.infer<typeof AgentAuthConfigSchema>;
export type AgentSessionOutputConfig = z.infer<typeof AgentSessionOutputConfigSchema>;
export type AgentRuntimeConfig = z.infer<typeof AgentRuntimeConfigSchema>;
export type CommandConfig = z.infer<typeof CommandConfigSchema>;
export type SearchCommandConfig = CommandConfig;
export type AnnotateCommandConfig = z.infer<typeof AnnotateCommandConfigSchema>;
export type CommandsConfig = z.infer<typeof CommandsConfigSchema>;
export type BackendRequestConfig = z.infer<typeof BackendRequestConfigSchema>;
