import * as test from 'node:test';
import * as assert from 'node:assert/strict';
import { ZodError } from 'zod';
import { EditAppliedResultSchema, parseBackendRequest, EditHunksResultSchema } from '.';

test('parseBackendRequest accepts an explainSelection request', () => {
	const parsed = parseBackendRequest({
		id: 'req-1',
		method: 'explainSelection',
		params: {
			filePath: '/repo/example.ex',
			language: 'elixir',
			text: 'defmodule Example do\nend',
			cursor: { line: 1, character: 1 },
			selectedText: 'defmodule Example do\nend',
			lens: { mode: 'learning', text: 'I am learning Elixir syntax' },
		},
	});

	assert.equal(parsed.id, 'req-1');
	assert.equal(parsed.method, 'explainSelection');
	assert.equal(parsed.params.language, 'elixir');
	assert.equal(parsed.params.lens?.mode, 'learning');
});

test('parseBackendRequest accepts a questionSelection request', () => {
	const parsed = parseBackendRequest({
		id: 'req-question',
		method: 'questionSelection',
		params: {
			filePath: '/repo/example.ts',
			language: 'typescript',
			text: 'const value = 1;',
			cursor: { line: 1, character: 1 },
			selectedText: 'const value = 1;',
			question: 'Why is this constant useful?',
		},
	});

	assert.equal(parsed.method, 'questionSelection');
	assert.equal(parsed.params.question, 'Why is this constant useful?');
	assert.equal(parsed.params.selectedText, 'const value = 1;');
});

test('parseBackendRequest accepts an editSelection request', () => {
	const parsed = parseBackendRequest({
		id: 'req-edit',
		method: 'editSelection',
		params: {
			filePath: '/repo/example.ts',
			language: 'typescript',
			text: 'const value = 1;',
			cursor: { line: 1, character: 1 },
			range: { startLine: 1, startCharacter: 1, endLine: 1, endCharacter: 16 },
			scopeText: 'const value = 1;',
			instruction: 'Rename value to count.',
		},
	});

	assert.equal(parsed.method, 'editSelection');
	assert.equal(parsed.params.instruction, 'Rename value to count.');
	assert.equal(parsed.params.range.startLine, 1);
});

test('parseBackendRequest accepts editSelection with runtime and file scope', () => {
	const parsed = parseBackendRequest({
		id: 'req-edit-file',
		method: 'editSelection',
		params: {
			filePath: '/repo/example.ts',
			language: 'typescript',
			text: 'const value = 1;',
			cursor: { line: 1, character: 1 },
			range: { startLine: 1, startCharacter: 1, endLine: 1, endCharacter: 16 },
			scopeText: 'const value = 1;',
			instruction: 'Rename value to count.',
			runtime: 'completion',
			scope: 'file',
		},
	});

	assert.equal(parsed.method, 'editSelection');
	if (parsed.method !== 'editSelection') {
		return;
	}
	assert.equal(parsed.params.runtime, 'completion');
	assert.equal(parsed.params.scope, 'file');
});

test('parseBackendRequest leaves editSelection runtime and scope undefined when omitted', () => {
	// Back-compat: every existing caller sends neither field.
	const parsed = parseBackendRequest({
		id: 'req-edit-default',
		method: 'editSelection',
		params: {
			filePath: '/repo/example.ts',
			language: 'typescript',
			text: 'const value = 1;',
			cursor: { line: 1, character: 1 },
			range: { startLine: 1, startCharacter: 1, endLine: 1, endCharacter: 16 },
			scopeText: 'const value = 1;',
			instruction: 'Rename value to count.',
		},
	});

	if (parsed.method !== 'editSelection') {
		return;
	}
	assert.equal(parsed.params.runtime, undefined);
	assert.equal(parsed.params.scope, undefined);
});

test('parseBackendRequest rejects an unknown editSelection scope', () => {
	assert.throws(() =>
		parseBackendRequest({
			id: 'req-edit-bad-scope',
			method: 'editSelection',
			params: {
				filePath: '/repo/example.ts',
				language: 'typescript',
				text: 'const value = 1;',
				cursor: { line: 1, character: 1 },
				range: { startLine: 1, startCharacter: 1, endLine: 1, endCharacter: 16 },
				scopeText: 'const value = 1;',
				instruction: 'Rename value to count.',
				scope: 'buffer',
			},
		})
	);
});

test('EditAppliedResultSchema round-trips an agent-owned acknowledgement', () => {
	const parsed = EditAppliedResultSchema.parse({
		kind: 'edit_applied',
		summary: 'Pi edited the workspace.',
	});

	assert.equal(parsed.kind, 'edit_applied');
	assert.equal(parsed.summary, 'Pi edited the workspace.');
});

test('EditHunksResultSchema round-trips a hunks result', () => {
	const parsed = EditHunksResultSchema.parse({
		kind: 'edits',
		hunks: [{ search: 'local a = 1', replace: 'local a = 2' }],
	});

	assert.equal(parsed.kind, 'edits');
	assert.equal(parsed.hunks.length, 1);
	assert.equal(parsed.hunks[0].search, 'local a = 1');
});

test('parseBackendRequest accepts a searchLocations request', () => {
	const parsed = parseBackendRequest({
		id: 'req-search',
		method: 'searchLocations',
		params: {
			workspaceRoot: '/repo',
			filePath: '/repo/example.ts',
			language: 'typescript',
			text: 'const value = 1;',
			cursor: { line: 1, character: 1 },
			query: 'find related factory calls',
		},
	});

	assert.equal(parsed.method, 'searchLocations');
	assert.equal(parsed.params.query, 'find related factory calls');
});

test('parseBackendRequest accepts a generateWalkthrough request', () => {
	const parsed = parseBackendRequest({
		id: 'req-walkthrough',
		method: 'generateWalkthrough',
		params: {
			workspaceRoot: '/repo',
			filePath: '/repo/example.ts',
			language: 'typescript',
			text: 'const value = 1;',
			cursor: { line: 1, character: 1 },
			prompt: 'Walk me through how value flows into the report.',
		},
	});

	assert.equal(parsed.method, 'generateWalkthrough');
	assert.equal(parsed.params.prompt, 'Walk me through how value flows into the report.');
});

test('parseBackendRequest accepts annotation candidate lines', () => {
	const parsed = parseBackendRequest({
		id: 'req-annotations',
		method: 'annotateRange',
		params: {
			filePath: '/repo/example.ts',
			language: 'typescript',
			text: 'const one = 1;\n// comment\nconst two = one + 1;',
			cursor: { line: 12, character: 1 },
			visibleRange: { startLine: 10, startCharacter: 1, endLine: 12, endCharacter: 20 },
			scopeText: 'const one = 1;\n// comment\nconst two = one + 1;',
			maxAnnotations: 5,
			candidateLines: [
				{ line: 10, text: 'const one = 1;' },
				{ line: 12, text: 'const two = one + 1;' },
			],
		},
	});

	assert.equal(parsed.method, 'annotateRange');
	assert.equal(parsed.params.maxAnnotations, 5);
	assert.deepEqual(parsed.params.candidateLines, [
		{ line: 10, text: 'const one = 1;' },
		{ line: 12, text: 'const two = one + 1;' },
	]);
});

test('parseBackendRequest accepts agent task context', () => {
	const parsed = parseBackendRequest({
		id: 'req-agent-context',
		method: 'explainSelection',
		params: {
			workspaceRoot: '/repo',
			filePath: '/repo/example.ts',
			language: 'typescript',
			text: 'const value = 1;',
			cursor: { line: 1, character: 1 },
			selectedText: 'const value = 1;',
			agentContext: {
				path: '/repo/.vantage/agent-context.md',
				content: '# Agent Task Context\n\n## Goal\nShip context',
				revision: 'rev-one',
				modifiedAt: '2026-05-21T12:00:00.000Z',
				ageMs: 1200,
				truncated: true,
			},
		},
	});

	assert.deepEqual(parsed.params.agentContext, {
		path: '/repo/.vantage/agent-context.md',
		content: '# Agent Task Context\n\n## Goal\nShip context',
		revision: 'rev-one',
		modifiedAt: '2026-05-21T12:00:00.000Z',
		ageMs: 1200,
		truncated: true,
	});
	assert.equal(parsed.params.workspaceRoot, '/repo');
});

test('parseBackendRequest accepts explicit agent and command config', () => {
	const parsed = parseBackendRequest({
		id: 'req-agent-config',
		method: 'explainSelection',
		config: {
			completion: {
				options: {
					customOption: 'preserved',
					maxTokens: 2048,
				},
			},
			agent: {
				provider: 'anthropic',
				model: 'claude-sonnet-4',
				auth: {
					path: '~/.config/pi-ai/auth.json',
				},
				options: {
					apiKey: 'sk-config',
					reasoning: 'medium',
					customAgentOption: 'preserved',
					temperature: 0.2,
					maxTokens: 2048,
					timeoutMs: 900000,
				},
			},
			commands: {
				question: {
					options: {
						maxTokens: 1536,
					},
				},
				annotate: {
					waiting_message_ms: 10,
					options: {
						maxTokens: 128,
						timeoutMs: 45000,
					},
				},
				edit: {
					options: {
						timeoutMs: 60000,
					},
				},
			},
		},
		params: {
			filePath: '/repo/example.ts',
			language: 'typescript',
			text: 'const value = 1;',
			cursor: { line: 1, character: 1 },
			selectedText: 'const value = 1;',
		},
	});

	assert.deepEqual(parsed.config?.completion, {
		options: {
			customOption: 'preserved',
			maxTokens: 2048,
		},
	});
	assert.deepEqual(parsed.config?.agent, {
		provider: 'anthropic',
		model: 'claude-sonnet-4',
		auth: {
			path: '~/.config/pi-ai/auth.json',
		},
		options: {
			apiKey: 'sk-config',
			reasoning: 'medium',
			customAgentOption: 'preserved',
			temperature: 0.2,
			maxTokens: 2048,
			timeoutMs: 900000,
		},
	});
	assert.deepEqual(parsed.config?.commands?.annotate, {
		waiting_message_ms: 10,
		options: {
			maxTokens: 128,
			timeoutMs: 45000,
		},
	});
	assert.deepEqual(parsed.config?.commands?.question, {
		options: {
			maxTokens: 1536,
		},
	});
	assert.deepEqual(parsed.config?.commands?.edit, {
		options: {
			timeoutMs: 60000,
		},
	});
});

test('parseBackendRequest rejects invalid annotation budgets', () => {
	assert.throws(
		() =>
			parseBackendRequest({
				id: 'req-annotations',
				method: 'annotateRange',
				params: {
					filePath: '/repo/example.ts',
					language: 'typescript',
					text: 'const value = 1;',
					cursor: { line: 1, character: 1 },
					scopeText: 'const value = 1;',
					maxAnnotations: 0,
				},
			}),
		ZodError
	);
});

test('parseBackendRequest rejects a request without an id', () => {
	assert.throws(
		() => parseBackendRequest({ method: 'explainSelection', params: {} }),
		ZodError
	);
});

test('parseBackendRequest rejects an unknown method', () => {
	assert.throws(
		() => parseBackendRequest({ id: 'req-1', method: 'unknown', params: {} }),
		ZodError
	);
});

test('parseBackendRequest rejects negative cursor coordinates', () => {
	assert.throws(
		() =>
			parseBackendRequest({
				id: 'req-1',
				method: 'explainSelection',
				params: {
					filePath: '/repo/example.ex',
					language: 'elixir',
					text: 'defmodule Example do\nend',
					cursor: { line: 0, character: 1 },
					selectedText: 'defmodule Example do\nend',
				},
			}),
		ZodError
	);
});

test('parseBackendRequest rejects floating range coordinates', () => {
	assert.throws(
		() =>
			parseBackendRequest({
				id: 'req-1',
				method: 'annotateRange',
				params: {
					filePath: '/repo/example.ts',
					language: 'typescript',
					text: 'const value = 1;',
					cursor: { line: 1, character: 1 },
					visibleRange: { startLine: 1.5, startCharacter: 1, endLine: 1, endCharacter: 16 },
					scopeText: 'const value = 1;',
				},
			}),
		ZodError
	);
});
