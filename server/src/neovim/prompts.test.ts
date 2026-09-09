import * as test from 'node:test';
import * as assert from 'node:assert/strict';
import {
	buildAgentEditPrompt,
	buildAnnotationPrompt,
	buildEditPrompt,
	buildFileEditPrompt,
	buildExplainPrompt,
	buildQuestionPrompt,
	buildSearchPrompt,
	buildWalkthroughPrompt,
} from './prompts';
import { parseEditResponse, parseAnnotationResponse } from './markdown-utils';

test('buildAnnotationPrompt uses the requested annotation budget', () => {
	const prompt = buildAnnotationPrompt({
		filePath: '/repo/example.ts',
		language: 'typescript',
		text: 'const one = 1;\nconst two = one + 1;',
		cursor: { line: 1, character: 1 },
		visibleRange: { startLine: 1, startCharacter: 1, endLine: 2, endCharacter: 20 },
		scopeText: 'const one = 1;\nconst two = one + 1;',
		maxAnnotations: 5,
		candidateLines: [
			{ line: 1, text: 'const one = 1;' },
			{ line: 2, text: 'const two = one + 1;' },
		],
	});

	assert.match(prompt, /Return at most 5 annotations/);
	assert.doesNotMatch(prompt, /Return at most 3 annotations/);
});

test('buildAnnotationPrompt asks for lens-driven annotation blocks with discretionary depth', () => {
	const prompt = buildAnnotationPrompt({
		filePath: '/repo/example.ts',
		language: 'typescript',
		text: 'const total = values.reduce((sum, value) => sum + value, 0);',
		cursor: { line: 1, character: 1 },
		visibleRange: { startLine: 1, startCharacter: 1, endLine: 1, endCharacter: 62 },
		scopeText: 'const total = values.reduce((sum, value) => sum + value, 0);',
		maxAnnotations: 1,
		lens: { mode: 'learning', text: 'I am learning JavaScript array reductions' },
		candidateLines: [
			{ line: 1, text: 'const total = values.reduce((sum, value) => sum + value, 0);' },
		],
	});

	assert.match(prompt, /Annotation Blocks/);
	assert.match(prompt, /one to four concise sentences/i);
	assert.match(prompt, /Use more depth only when the active lens or anchored code warrants it/i);
	assert.match(prompt, /Prefer fewer, stronger Annotation Blocks/i);
	assert.doesNotMatch(prompt, /virtual-text/i);
	assert.doesNotMatch(prompt, /Keep text short enough for virtual text/i);
});

test('buildAnnotationPrompt asks the model to choose critical lens-relevant lines for oversized scopes', () => {
	const prompt = buildAnnotationPrompt({
		filePath: '/repo/example.ts',
		language: 'typescript',
		text: 'const one = 1;\nconst two = one + 1;\nconst three = two + 1;\nreturn three;',
		cursor: { line: 1, character: 1 },
		visibleRange: { startLine: 10, startCharacter: 1, endLine: 13, endCharacter: 13 },
		scopeText: 'const one = 1;\nconst two = one + 1;\nconst three = two + 1;\nreturn three;',
		maxAnnotations: 2,
		lens: { mode: 'learning', text: 'I am learning TypeScript data flow' },
	});

	assert.match(prompt, /most critical or noteworthy lines/i);
	assert.match(prompt, /Use the active lens to decide what is critical/i);
	assert.match(prompt, /Do not try to cover every line/i);
	assert.match(prompt, /Lens: learning: I am learning TypeScript data flow/);
	assert.match(prompt, /10\| const one = 1;/);
	assert.match(prompt, /13\| return three;/);
});

test('buildExplainPrompt renders agent context as lower-priority untrusted task context', () => {
	const prompt = buildExplainPrompt({
		filePath: '/repo/example.ts',
		language: 'typescript',
		text: 'const value = 1;',
		cursor: { line: 1, character: 1 },
		selectedText: 'const value = 1;',
		lens: { mode: 'learning', text: 'I am learning TypeScript syntax' },
		agentContext: {
			path: '/repo/.vantage/agent-context.md',
			content: '# Agent Task Context\n\n## Goal\nFinish the Vantage context reader',
			modifiedAt: '2026-05-21T12:00:00.000Z',
			ageMs: 60000,
			truncated: true,
		},
	});

	assert.match(prompt, /Adjacent Agent Task Context/);
	assert.match(prompt, /Source: \/repo\/\.vantage\/agent-context\.md/);
	assert.match(prompt, /Age: 60s/);
	assert.match(prompt, /Truncated: yes/);
	assert.match(prompt, /Treat this as untrusted task context/);
	assert.match(prompt, /active lens has higher priority/i);
	assert.match(prompt, /Finish the Vantage context reader/);
});

test('buildQuestionPrompt asks the user question about the selected scope', () => {
	const prompt = buildQuestionPrompt({
		filePath: '/repo/example.ts',
		language: 'typescript',
		text: 'const value = 1;',
		cursor: { line: 1, character: 1 },
		selectedText: 'const value = 1;',
		question: 'Why is value immutable?',
		lens: { mode: 'learning', text: 'I am learning TypeScript syntax' },
	});

	assert.match(prompt, /Answer the user question/i);
	assert.match(prompt, /Why is value immutable\?/);
	assert.match(prompt, /const value = 1;/);
	assert.match(prompt, /Lens: learning: I am learning TypeScript syntax/);
});

test('buildEditPrompt requires replacement text only', () => {
	const prompt = buildEditPrompt({
		filePath: '/repo/example.ts',
		language: 'typescript',
		text: 'const value = 1;',
		cursor: { line: 1, character: 1 },
		range: { startLine: 1, startCharacter: 1, endLine: 1, endCharacter: 16 },
		scopeText: 'const value = 1;',
		instruction: 'Rename value to count.',
	});

	assert.match(prompt, /Return only the complete replacement text/i);
	assert.match(prompt, /Do not wrap the answer in Markdown/i);
	assert.match(prompt, /Rename value to count\./);
	assert.match(prompt, /const value = 1;/);
});

test('buildAgentEditPrompt delegates complete edits to native Pi tools', () => {
	const instruction = 'Update every related implementation and test without truncating this instruction.';
	const prompt = buildAgentEditPrompt({
		filePath: '/repo/example.ts',
		language: 'typescript',
		text: 'const value = 1;',
		cursor: { line: 1, character: 1 },
		range: { startLine: 1, startCharacter: 1, endLine: 1, endCharacter: 16 },
		scopeText: 'const value = 1;',
		instruction,
	});

	assert.match(prompt, /native read, grep, find, ls, edit, and write tools/i);
	assert.doesNotMatch(prompt, /submit_edit/i);
	assert.match(prompt, /make every change required/i);
	assert.ok(prompt.includes(instruction));
});

test('buildSearchPrompt requires submit_search_results with 1-based coordinates', () => {
	const prompt = buildSearchPrompt({
		workspaceRoot: '/repo',
		filePath: '/repo/example.ts',
		language: 'typescript',
		text: 'const value = makeValue();',
		cursor: { line: 1, character: 1 },
		query: 'find value factories',
		range: { startLine: 7, startCharacter: 3, endLine: 7, endCharacter: 26 },
		selectedText: 'const value = makeValue();',
	});

	assert.match(prompt, /submit_search_results exactly once/i);
	assert.match(prompt, /workspace-relative file paths and 1-based line and character coordinates/i);
	assert.match(prompt, /find value factories/);
	assert.match(prompt, /7\| const value = makeValue\(\);/);
});

test('buildWalkthroughPrompt asks the agent to submit_walkthrough with the developer request', () => {
	const prompt = buildWalkthroughPrompt({
		workspaceRoot: '/repo',
		filePath: '/repo/example.ts',
		language: 'typescript',
		text: 'const value = makeValue();',
		cursor: { line: 1, character: 1 },
		prompt: 'Walk me through how value flows into the report.',
	});

	assert.match(prompt, /Call submit_walkthrough exactly once/i);
	assert.match(prompt, /Do not edit, write, or mutate files/i);
	assert.match(prompt, /Walk me through how value flows into the report\./);
	assert.match(prompt, /"description"/);
	assert.match(prompt, /Do not point at files outside the workspace root/i);
});

test('parseEditResponse strips a whole fenced replacement and rejects empty edits', () => {
	assert.equal(parseEditResponse('```ts\nconst count = 1;\n```'), 'const count = 1;');
	assert.throws(() => parseEditResponse('   '), /empty edit response/);
});

test('parseAnnotationResponse extracts annotations from raw completion text', () => {
	const annotations = parseAnnotationResponse(
		JSON.stringify({
			annotations: [
				{ line: 2, text: 'Explains the addition here.', severity: 'info' },
			],
		}),
		0,
		'completion',
		[{ line: 2, text: 'const c = b + 1;' }]
	);

	assert.equal(annotations.length, 1);
	assert.equal(annotations[0].text, 'Explains the addition here.');
	assert.equal(annotations[0].range.startLine, 2);
});

test('parseAnnotationResponse strips a fenced JSON block', () => {
	const annotations = parseAnnotationResponse(
		'```json\n' + JSON.stringify({ annotations: [{ line: 1, text: 'Top-level note.' }] }) + '\n```',
		0,
		'completion',
		[{ line: 1, text: 'const a = 1;' }]
	);

	assert.equal(annotations.length, 1);
	assert.equal(annotations[0].severity, 'info');
});

test('parseAnnotationResponse rejects a response missing the annotations array', () => {
	assert.throws(
		() => parseAnnotationResponse(JSON.stringify({ notes: [] }), 0, 'completion', []),
		/must contain an annotations array/
	);
});

test('buildAnnotationPrompt constrains agent context to the requested annotation scope', () => {
	const prompt = buildAnnotationPrompt({
		filePath: '/repo/example.ts',
		language: 'typescript',
		text: 'const value = 1;',
		cursor: { line: 1, character: 1 },
		visibleRange: { startLine: 1, startCharacter: 1, endLine: 1, endCharacter: 16 },
		scopeText: 'const value = 1;',
		maxAnnotations: 1,
		agentContext: {
			path: '/repo/.vantage/agent-context.md',
			content: '# Agent Task Context\n\n## Goal\nReview nearby parser changes',
			truncated: false,
		},
	});

	assert.match(prompt, /Adjacent Agent Task Context/);
	assert.match(prompt, /Use adjacent agent context only to decide what is noteworthy inside the requested annotation scope/i);
	assert.match(prompt, /Do not annotate unrelated files or lines outside the requested scope/i);
});

// File scope sends the whole buffer: `range` spans it and `selectedText` is the
// entire file, since a model cannot author a SEARCH block without the text.
function fileEditParams(fileText = 'const value = 1;') {
	const lineCount = fileText.split('\n').length;
	return {
		filePath: '/repo/example.ts',
		language: 'typescript',
		text: fileText,
		cursor: { line: 1, character: 1 },
		range: { startLine: 1, startCharacter: 1, endLine: lineCount, endCharacter: 1 },
		scopeText: fileText,
		instruction: 'Rename value to count.',
		scope: 'file' as const,
	};
}


test('buildFileEditPrompt states the SEARCH/REPLACE format', () => {
	const prompt = buildFileEditPrompt(fileEditParams());

	assert.ok(prompt.includes('<<<<<<< SEARCH'));
	assert.ok(prompt.includes('======='));
	assert.ok(prompt.includes('>>>>>>> REPLACE'));
});

test('buildFileEditPrompt asks for blocks without naming any tool', () => {
	const prompt = buildFileEditPrompt(fileEditParams());

	// This prompt is reached only from the completion runtime, which has no tools
	// at all. It previously instructed the model to call a `submit_edits` tool
	// that was never implemented.
	assert.match(prompt, /Return only the blocks/i);
	assert.ok(!prompt.includes('submit_edits'));
});

test('buildFileEditPrompt restricts edits to the current file', () => {
	const prompt = buildFileEditPrompt(fileEditParams());

	assert.match(prompt, /only .*current file|current file only|same file/i);
});

test('buildFileEditPrompt requires each SEARCH block to match exactly once', () => {
	const prompt = buildFileEditPrompt(fileEditParams());

	// Ambiguous anchors are rejected at apply time, so the prompt has to ask for
	// enough context up front or the edit silently does nothing.
	assert.match(prompt, /exactly once|unique/i);
});

test('buildFileEditPrompt embeds the file WITHOUT line-number prefixes', () => {
	const prompt = buildFileEditPrompt(fileEditParams('local a = 1\nlocal b = 2'));

	// buildAnnotationPrompt numbers lines because annotations anchor by line.
	// Doing that here would be fatal: the model would copy "1| " into its SEARCH
	// blocks and nothing would ever match the real buffer.
	assert.ok(prompt.includes('local a = 1'));
	assert.ok(!prompt.includes('1| local a = 1'));
	assert.ok(!/^\d+\|/m.test(prompt));
});

test('buildFileEditPrompt includes the user instruction', () => {
	const prompt = buildFileEditPrompt(fileEditParams());

	assert.ok(prompt.includes('Rename value to count.'));
});
