import * as fs from 'node:fs';
import * as path from 'node:path';
import { z } from 'zod';
import type * as PiAi from '@earendil-works/pi-ai';
import type { ToolDefinition } from '@earendil-works/pi-coding-agent';
import type { Annotation, AnnotateRangeParams, BaseRequestParams, SearchLocation, WalkthroughPointer } from './protocol';
import { parseAnnotationPayload } from './markdown-utils';
import { errorMessage } from './effect-errors';
import { JsonRecordSchema, JsonValueSchema, type JsonRecord, type JsonValue } from './utils';

export interface SubmitToolHandlers {
	onSearch?: (locations: SearchLocation[]) => void;
	onAnnotations?: (annotations: Annotation[]) => void;
	onWalkthrough?: (pointers: WalkthroughPointer[]) => void;
}

export interface SubmitToolSubmission {
	params: BaseRequestParams;
	handlers: SubmitToolHandlers;
	outputEntryId?: string;
}

export interface SubmitToolOutputRecorder {
	appendOutputEvent?(entryId: string | undefined, event: { type: string; summary: string; details?: unknown }): void;
}

interface CreateSubmitToolsOptions {
	Type: typeof PiAi.Type;
	defineTool<T extends ToolDefinition>(tool: T): T;
	requireSubmission(toolName: string): SubmitToolSubmission;
	workspaceRoot(params: BaseRequestParams): string;
	output: SubmitToolOutputRecorder;
}

// ─── Zod payload schemas ─────────────────────────────────────────────

const workspaceRelativePathSchema = z
	.string()
	.min(1)
	.refine((value) => !path.isAbsolute(value) && !value.includes('..'), {
		message: "must be a workspace-relative path without '..'",
	});

const singleLineStringSchema = z
	.string()
	.min(1)
	.refine((value) => !/[\r\n]/.test(value), { message: 'must be a single-line string' });

const SearchLocationPayloadSchema = z.object({
	filePath: workspaceRelativePathSchema,
	startLine: z.number().int().min(1),
	startCharacter: z.number().int().min(1),
	lineCount: z.number().int().min(1).optional(),
	explanation: singleLineStringSchema,
});

const SubmitSearchResultsPayloadSchema = z.object({
	locations: z.array(SearchLocationPayloadSchema),
});

const WalkthroughPointerPayloadSchema = z.object({
	file: workspaceRelativePathSchema,
	line: z.number().int().min(1),
	anchor: z.string().optional(),
	description: singleLineStringSchema,
});

const SubmitWalkthroughPayloadSchema = z.object({
	pointers: z.array(WalkthroughPointerPayloadSchema),
});

// ─── Tool definitions ────────────────────────────────────────────────

export function createSubmitTools(options: CreateSubmitToolsOptions): ToolDefinition[] {
	const submitSearch = options.defineTool({
		name: 'submit_search_results',
		label: 'Submit Search Results',
		description: 'Submit the final curated Vantage search locations. Call exactly once after searching.',
		parameters: options.Type.Object({
			locations: options.Type.Array(options.Type.Object({
				filePath: options.Type.String({ description: 'Workspace-relative file path.' }),
				startLine: options.Type.Number({ description: '1-based start line.' }),
				startCharacter: options.Type.Number({ description: '1-based start character.' }),
				lineCount: options.Type.Optional(options.Type.Number({ description: 'Number of lines covered.' })),
				explanation: options.Type.String({ description: 'Concise single-line explanation for quickfix.' }),
			})),
		}),
		executionMode: 'sequential' as const,
		execute: async (_toolCallId, payload) => {
			const submission = options.requireSubmission('submit_search_results');
			// SAFETY: `payload`'s static type collapses to `unknown` because
			// `defineTool`'s generic inference can't narrow it from the sibling
			// `parameters` schema through this SDK interface; tool-call arguments
			// always arrive JSON-decoded, so this is `JsonValue` at runtime.
			const record = requireRecord(payload as JsonValue, 'submit_search_results');
			const validation = validateSearchLocations(options.workspaceRoot(submission.params), record.locations);
			if (!validation.ok) {
				throw new Error(validation.message);
			}
			submission.handlers.onSearch?.(validation.locations);
			options.output.appendOutputEvent?.(submission.outputEntryId, {
				type: 'submit_search_results',
				summary: `Accepted ${validation.locations.length} Vantage search result(s).`,
				details: { locations: validation.locations },
			});
			return {
				content: [{ type: 'text' as const, text: `Accepted ${validation.locations.length} Vantage search result(s).` }],
				details: { locations: validation.locations },
				terminate: true,
			};
		},
	});
	const submitAnnotations = options.defineTool({
		name: 'submit_annotations',
		label: 'Submit Annotations',
		description: 'Submit final Vantage annotation blocks for the requested scope.',
		parameters: options.Type.Object({ annotations: options.Type.Array(options.Type.Unknown()) }),
		executionMode: 'sequential' as const,
		execute: async (_toolCallId, payload) => {
			const submission = options.requireSubmission('submit_annotations');
			// SAFETY: `annotations` is declared `Type.Unknown()` because each entry's
			// shape is only validated below by `AnnotationPayloadSchema`; tool-call
			// arguments always arrive JSON-decoded, so this is `JsonValue`, not truly
			// arbitrary (no functions/symbols).
			const record = requireRecord(payload as JsonValue, 'submit_annotations');
			if (!isAnnotateParams(submission.params)) {
				throw new Error('submit_annotations can only be used for annotate requests.');
			}
			const annotations = parseAnnotationPayload(record.annotations, submission.params);
			submission.handlers.onAnnotations?.(annotations);
			options.output.appendOutputEvent?.(submission.outputEntryId, {
				type: 'submit_annotations',
				summary: `Accepted ${annotations.length} Vantage annotation(s).`,
				details: { annotations },
			});
			return {
				content: [{ type: 'text' as const, text: `Accepted ${annotations.length} Vantage annotation(s).` }],
				details: { annotations },
				terminate: true,
			};
		},
	});
	const submitWalkthrough = options.defineTool({
		name: 'submit_walkthrough',
		label: 'Submit Walkthrough',
		description: 'Submit the final ordered Vantage walkthrough pointers. Call exactly once after reading the relevant code.',
		parameters: options.Type.Object({
			pointers: options.Type.Array(options.Type.Object({
				file: options.Type.String({ description: 'Workspace-relative file path.' }),
				line: options.Type.Number({ description: '1-based line the note is about.' }),
				anchor: options.Type.Optional(options.Type.String({ description: 'Exact current text of the line, for staleness detection.' })),
				description: options.Type.String({ description: 'Concise single-line note for this pointer.' }),
			})),
		}),
		executionMode: 'sequential' as const,
		execute: async (_toolCallId, payload) => {
			const submission = options.requireSubmission('submit_walkthrough');
			// SAFETY: see the `submit_search_results` tool above — `payload` is
			// `unknown` only because of a generic-inference limitation through
			// this SDK interface; it is always a JSON-decoded tool-call argument.
			const record = requireRecord(payload as JsonValue, 'submit_walkthrough');
			const validation = validateWalkthroughPointers(options.workspaceRoot(submission.params), record.pointers);
			if (!validation.ok) {
				throw new Error(validation.message);
			}
			submission.handlers.onWalkthrough?.(validation.pointers);
			options.output.appendOutputEvent?.(submission.outputEntryId, {
				type: 'submit_walkthrough',
				summary: `Accepted ${validation.pointers.length} Vantage walkthrough pointer(s).`,
				details: { pointers: validation.pointers },
			});
			return {
				content: [{ type: 'text' as const, text: `Accepted ${validation.pointers.length} Vantage walkthrough pointer(s).` }],
				details: { pointers: validation.pointers },
				terminate: true,
			};
		},
	});
	return [submitSearch, submitAnnotations, submitWalkthrough];
}

export function parseSearchFallback(workspaceRootPath: string, text: string): SearchLocation[] {
	const value = parseAssistantJson(text, 'Vantage search fallback');
	const validation = validateSearchLocations(workspaceRootPath, requireRecord(value, 'Vantage search fallback').locations);
	if (!validation.ok) {
		throw new Error(validation.message);
	}
	return validation.locations;
}

export function parseWalkthroughFallback(workspaceRootPath: string, text: string): WalkthroughPointer[] {
	const value = parseAssistantJson(text, 'Vantage walkthrough fallback');
	const validation = validateWalkthroughPointers(
		workspaceRootPath,
		requireRecord(value, 'Vantage walkthrough fallback').pointers
	);
	if (!validation.ok) {
		throw new Error(validation.message);
	}
	return validation.pointers;
}

// ─── Validation ──────────────────────────────────────────────────────

function validateSearchLocations(
	workspaceRootPath: string,
	rawLocations: JsonValue | undefined
): { ok: true; locations: SearchLocation[] } | { ok: false; message: string } {
	const parsedPayload = SubmitSearchResultsPayloadSchema.safeParse({ locations: rawLocations });
	if (!parsedPayload.success) {
		return {
			ok: false,
			message: formatValidationError('Invalid search results', formatZodIssues(parsedPayload.error.issues), 'submit_search_results'),
		};
	}

	const errors: string[] = [];
	const locations: SearchLocation[] = [];
	const seen = new Set<string>();
	for (const [index, candidate] of parsedPayload.data.locations.entries()) {
		const label = `locations[${index}]`;
		const absolutePath = path.resolve(workspaceRootPath, candidate.filePath);
		const relative = path.relative(workspaceRootPath, absolutePath);
		if (relative.startsWith('..') || path.isAbsolute(relative)) {
			errors.push(`${label}.filePath: must be under the workspace root.`);
			continue;
		}
		if (!fs.existsSync(absolutePath) || !fs.statSync(absolutePath).isFile()) {
			errors.push(`${label}.filePath: file does not exist under the workspace root.`);
			continue;
		}
		const fileLineCount = fs.readFileSync(absolutePath, 'utf8').split(/\r?\n/).length;
		if (candidate.startLine > fileLineCount) {
			errors.push(`${label}.startLine: must be a 1-based line within file length ${fileLineCount}.`);
		}
		const key = `${candidate.filePath}:${String(candidate.startLine)}:${String(candidate.startCharacter)}`;
		if (seen.has(key)) {
			errors.push(`${label}: duplicate location ${key}.`);
		}
		seen.add(key);
		if (errors.length === 0 || !errors.some((error) => error.startsWith(label))) {
			locations.push({
				filePath: candidate.filePath,
				startLine: candidate.startLine,
				startCharacter: candidate.startCharacter,
				lineCount: candidate.lineCount,
				explanation: candidate.explanation,
			});
		}
	}
	if (errors.length > 0) {
		return {
			ok: false,
			message: formatValidationError('Invalid search results', errors, 'submit_search_results'),
		};
	}
	return { ok: true, locations };
}

function validateWalkthroughPointers(
	workspaceRootPath: string,
	rawPointers: JsonValue | undefined
): { ok: true; pointers: WalkthroughPointer[] } | { ok: false; message: string } {
	const parsedPayload = SubmitWalkthroughPayloadSchema.safeParse({ pointers: rawPointers });
	if (!parsedPayload.success) {
		return {
			ok: false,
			message: formatValidationError('Invalid walkthrough pointers', formatZodIssues(parsedPayload.error.issues), 'submit_walkthrough'),
		};
	}

	const errors: string[] = [];
	const pointers: WalkthroughPointer[] = [];
	for (const [index, candidate] of parsedPayload.data.pointers.entries()) {
		const label = `pointers[${index}]`;
		const absolutePath = path.resolve(workspaceRootPath, candidate.file);
		const relative = path.relative(workspaceRootPath, absolutePath);
		if (relative.startsWith('..') || path.isAbsolute(relative)) {
			errors.push(`${label}.file: must be under the workspace root.`);
			continue;
		}
		if (!fs.existsSync(absolutePath) || !fs.statSync(absolutePath).isFile()) {
			errors.push(`${label}.file: file does not exist under the workspace root.`);
			continue;
		}
		const fileLineCount = fs.readFileSync(absolutePath, 'utf8').split(/\r?\n/).length;
		if (candidate.line > fileLineCount) {
			errors.push(`${label}.line: must be a 1-based line within file length ${fileLineCount}.`);
		}
		if (errors.length === 0 || !errors.some((error) => error.startsWith(label))) {
			pointers.push({
				file: candidate.file,
				line: candidate.line,
				anchor: candidate.anchor,
				description: candidate.description,
			});
		}
	}
	if (errors.length > 0) {
		return {
			ok: false,
			message: formatValidationError('Invalid walkthrough pointers', errors, 'submit_walkthrough'),
		};
	}
	return { ok: true, pointers };
}

function requireRecord(value: JsonValue | undefined, label: string): JsonRecord {
	const parsed = JsonRecordSchema.safeParse(value);
	if (!parsed.success) {
		throw new Error(`${label} must be an object.`);
	}
	return parsed.data;
}

function formatValidationError(title: string, errors: string[], toolName: string): string {
	return [
		title + ':',
		...errors.map((error) => `- ${error}`),
		`Please call ${toolName} again with corrected final results only.`,
	].join('\n');
}

function formatZodIssues(issues: z.ZodIssue[]): string[] {
	return issues.map((issue) => {
		const pathLabel = issue.path
			.map((segment) => (Number.isInteger(segment) ? `[${String(segment)}]` : `.${String(segment)}`))
			.join('')
			.replace(/^\./, '');
		return pathLabel.length > 0 ? `${pathLabel}: ${issue.message}` : issue.message;
	});
}

function parseAssistantJson(text: string, label: string): JsonValue {
	const trimmed = text.trim();
	const fence = trimmed.match(/^```(?:json)?\s*\n([\s\S]*?)\n```$/i);
	const candidate = fence ? fence[1].trim() : trimmed;
	let parsed: unknown;
	try {
		parsed = JSON.parse(candidate);
	} catch (error) {
		const start = candidate.indexOf('{');
		const end = candidate.lastIndexOf('}');
		if (start >= 0 && end > start) {
			try {
				parsed = JSON.parse(candidate.slice(start, end + 1));
			} catch {
				throw new Error(`${label} did not return valid JSON: ${errorMessage(error)}`);
			}
		} else {
			throw new Error(`${label} did not return valid JSON: ${errorMessage(error)}`);
		}
	}
	const validated = JsonValueSchema.safeParse(parsed);
	if (!validated.success) {
		throw new Error(`${label} did not return valid JSON.`);
	}
	return validated.data;
}

function isAnnotateParams(params: BaseRequestParams): params is AnnotateRangeParams {
	return 'scopeText' in params;
}