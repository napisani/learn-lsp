import { z } from 'zod';

/**
 * A value that has crossed a JSON boundary (JSON-RPC request/response body,
 * `JSON.parse` output, an agent tool-call payload): any JSON-serializable
 * value, but nothing else (no functions, symbols, or class instances).
 * Callers must validate the specific contract they expect (typically with a
 * zod schema) before relying on it.
 */
export type JsonValue = string | number | boolean | null | JsonValue[] | JsonRecord;

export interface JsonRecord {
	[key: string]: JsonValue | undefined;
}

export const JsonValueSchema: z.ZodType<JsonValue> = z.lazy(() =>
	z.union([z.string(), z.number(), z.boolean(), z.null(), z.array(JsonValueSchema), JsonRecordSchema])
);

export const JsonRecordSchema: z.ZodType<JsonRecord> = z.lazy(() =>
	z.record(z.string(), z.optional(JsonValueSchema))
);
