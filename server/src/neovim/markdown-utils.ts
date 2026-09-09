import { z } from 'zod';
import type { AnnotateRangeParams, Annotation, AnnotationCandidateLine, EditHunk, Range } from './protocol';
import { JsonRecordSchema, type JsonRecord, type JsonValue } from './utils';

export function codeBlock(language: string, content: string): string {
	return ['```' + language, content, '```'].join('\n');
}

export function numberedCodeBlock(content: string, startLine = 1): string {
	const numberedLines = content.split('\n').map((line, index) => `${startLine + index}| ${line}`);
	return ['```text', ...numberedLines, '```'].join('\n');
}

export function candidateCodeBlock(candidateLines: AnnotationCandidateLine[]): string {
	const numberedLines = candidateLines.map((candidate) => `${candidate.line}| ${candidate.text}`);
	return ['```text', ...numberedLines, '```'].join('\n');
}

export function stripWholeFence(content: string): string {
	const match = content.match(/^```[^\n]*\n([\s\S]*?)\n```$/);
	return match ? match[1].trim() : content;
}

export function parseJsonObject(content: string, label: string): JsonRecord {
	const trimmed = content.trim();
	const jsonText = trimmed.startsWith('```') ? stripWholeFence(trimmed) : trimmed;

	let parsed: unknown;
	try {
		parsed = JSON.parse(jsonText);
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		throw new Error(`${label} annotation response was not valid JSON: ${message}`);
	}

	const object = JsonRecordSchema.safeParse(parsed);
	if (!object.success) {
		throw new Error(`${label} annotation response was not valid JSON: response was not an object.`);
	}
	return object.data;
}

export function parseAnnotationResponse(
	content: string,
	lineOffset = 0,
	label = 'Model',
	candidateLines: AnnotationCandidateLine[] = []
): Annotation[] {
	const parsed = parseJsonObject(content, label);
	const annotations = parsed.annotations;
	if (!Array.isArray(annotations)) {
		throw new Error(`${label} annotation response must contain an annotations array.`);
	}

	return annotations.map((annotation, index) =>
		addLineOffset(parseAnnotation(annotation, index, label, candidateLines), lineOffset)
	);
}

export function parseEditResponse(content: string): string {
	const trimmed = content.trim();
	const text = trimmed.startsWith('```') ? stripWholeFence(trimmed) : content;
	if (text.trim().length === 0) {
		throw new Error('Pi produced an empty edit response.');
	}
	return text;
}

const SEARCH_MARKER = '<<<<<<< SEARCH';
const DIVIDER_MARKER = '=======';
const REPLACE_MARKER = '>>>>>>> REPLACE';

/**
 * Parses aider-style SEARCH/REPLACE blocks out of a model response.
 *
 * Driven off the git merge-conflict markers rather than fence boundaries. That
 * is not a stylistic choice: a replacement body legitimately contains ``` when
 * the edit inserts a doc comment or a markdown example, and a fence-splitting
 * parser truncates the block there. avante carries that exact bug (issue #832).
 *
 * The fence and the filename line are optional decoration -- a model may omit
 * either -- so only the markers are treated as structure.
 */
export function parseSearchReplaceBlocks(content: string): EditHunk[] {
	const lines = (content ?? '').replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');
	const hunks: EditHunk[] = [];

	for (let index = 0; index < lines.length; index += 1) {
		if (lines[index].trim() !== SEARCH_MARKER) {
			continue;
		}

		const searchLines: string[] = [];
		let cursor = index + 1;
		while (cursor < lines.length && lines[cursor].trim() !== DIVIDER_MARKER) {
			if (lines[cursor].trim() === REPLACE_MARKER) {
				throw new Error('SEARCH/REPLACE block is missing its ======= divider.');
			}
			searchLines.push(lines[cursor]);
			cursor += 1;
		}
		if (cursor >= lines.length) {
			throw new Error('SEARCH/REPLACE block is missing its ======= divider.');
		}

		const replaceLines: string[] = [];
		cursor += 1;
		while (cursor < lines.length && lines[cursor].trim() !== REPLACE_MARKER) {
			if (lines[cursor].trim() === SEARCH_MARKER) {
				throw new Error('SEARCH/REPLACE block is unterminated: a new block started before >>>>>>> REPLACE.');
			}
			replaceLines.push(lines[cursor]);
			cursor += 1;
		}
		if (cursor >= lines.length) {
			throw new Error('SEARCH/REPLACE block is unterminated: no >>>>>>> REPLACE marker.');
		}

		const search = searchLines.join('\n');
		if (search.trim().length === 0) {
			// aider reads an empty SEARCH as "create this file". Vantage only ever
			// edits the current buffer, so this can only be a malformed edit --
			// and applying it would splice text at an arbitrary position.
			throw new Error('SEARCH/REPLACE block has an empty SEARCH body.');
		}

		hunks.push({ search, replace: replaceLines.join('\n'), filePath: filePathAbove(lines, index) });
		index = cursor;
	}

	return hunks;
}

/**
 * The path a model wrote above the block, skipping the opening fence and any
 * blank lines between. Returns undefined when the line is prose rather than a
 * path, so an editorializing model does not produce a bogus target.
 */
function filePathAbove(lines: string[], searchMarkerIndex: number): string | undefined {
	for (let index = searchMarkerIndex - 1; index >= 0 && index >= searchMarkerIndex - 3; index -= 1) {
		const candidate = lines[index].trim();
		if (candidate.length === 0 || candidate.startsWith('```')) {
			continue;
		}
		// A path, not a sentence: no whitespace, and it looks like a filename.
		return /^[^\s]+\.[^\s.]+$/.test(candidate) ? candidate : undefined;
	}
	return undefined;
}

export function parseAnnotationPayload(values: JsonValue | undefined, params: AnnotateRangeParams): Annotation[] {
	if (!Array.isArray(values)) {
		throw new Error('submit_annotations.annotations must be an array.');
	}
	return values.map((value, index) => parseAnnotation(value, index, 'submit_annotations', params.candidateLines ?? []));
}

export function addLineOffset(annotation: Annotation, lineOffset: number): Annotation {
	if (lineOffset === 0) {
		return annotation;
	}

	return {
		...annotation,
		range: {
			...annotation.range,
			startLine: annotation.range.startLine + lineOffset,
			endLine: annotation.range.endLine + lineOffset,
		},
	};
}

const CoordinateSchema = z.number().int().min(1);

const AnnotationRangeSchema = z.object({
	startLine: CoordinateSchema,
	startCharacter: CoordinateSchema,
	endLine: CoordinateSchema,
	endCharacter: CoordinateSchema,
});

const AnnotationPayloadSchema = z
	.object({
		text: z.string().refine((value) => value.trim().length > 0, 'must include non-empty text'),
		severity: z.enum(['info', 'warning']).optional(),
		detailMarkdown: z.string().optional(),
		line: CoordinateSchema.optional(),
		range: AnnotationRangeSchema.optional(),
	})
	.refine((value) => value.line !== undefined || value.range !== undefined, {
		message: 'must include either a line or a range',
		path: ['line'],
	});

function parseAnnotation(
	value: JsonValue,
	index: number,
	label: string,
	candidateLines: AnnotationCandidateLine[]
): Annotation {
	const parsed = AnnotationPayloadSchema.safeParse(value);
	if (!parsed.success) {
		const details = parsed.error.issues.map((issue) => issue.message).join('; ');
		throw new Error(`${label} annotation at index ${index} is invalid: ${details}`);
	}

	const { text, severity, detailMarkdown, line, range } = parsed.data;
	return {
		range: line !== undefined ? rangeFromCandidateLine(line, candidateLines) : range!,
		text,
		severity: severity ?? 'info',
		detailMarkdown,
	};
}

function rangeFromCandidateLine(line: number, candidateLines: AnnotationCandidateLine[]): Range {
	const candidate = candidateLines.find((item) => item.line === line);
	return {
		startLine: line,
		startCharacter: 1,
		endLine: line,
		endCharacter: candidate ? Math.max(1, candidate.text.length) : 1,
	};
}
