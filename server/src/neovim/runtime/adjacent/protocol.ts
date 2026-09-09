import { z } from 'zod';

export const RequestSchema = z.object({
	version: z.literal(1),
	method: z.enum(['probe', 'snapshot']),
	workspaceRoot: z.string(),
});
export type BridgeRequest = z.infer<typeof RequestSchema>;

export const SnapshotSchema = z.object({
	sessionId: z.string().min(1),
	leafId: z.string().nullable(),
	workspaceRoot: z.string(),
	provider: z.string().min(1),
	model: z.string().min(1),
	thinkingLevel: z.string(),
	// Native Pi JSONL, not a lossy transcript or a path into a live session file.
	branch: z.string(),
	entryCount: z.number().int().nonnegative(),
	parentBusy: z.boolean().optional(),
});
export type Snapshot = z.infer<typeof SnapshotSchema>;

export const ResponseSchema = z.discriminatedUnion('kind', [
	z.object({ version: z.literal(1), kind: z.literal('ready') }),
	z.object({ version: z.literal(1), kind: z.literal('snapshot'), snapshot: SnapshotSchema }),
	z.object({ version: z.literal(1), kind: z.literal('error'), message: z.string() }),
]);
export type BridgeResponse = z.infer<typeof ResponseSchema>;
export const MAX_RESPONSE_BYTES = 32 * 1024 * 1024;
export const IPC_TIMEOUT_MS = 5000;
