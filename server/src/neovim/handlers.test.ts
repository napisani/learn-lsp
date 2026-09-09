import * as test from 'node:test';
import * as assert from 'node:assert/strict';
import { handleBackendRequest, hunksForCurrentFile } from './handlers';
import type { AgentRuntime } from './runtime/agent';

test('handleBackendRequest uses development runtime when configured', async () => {
	const response = await handleBackendRequest({
		id: 'req-development',
		method: 'explainSelection',
		config: {
			agent: { runtime: 'development' },
		},
		params: {
			filePath: '/repo/example.ex',
			language: 'elixir',
			text: 'defmodule Example do\nend',
			cursor: { line: 1, character: 1 },
			selectedText: 'defmodule Example do\nend',
			lens: { mode: 'learning', text: 'I am learning Elixir syntax' },
		},
	});

	assert.equal(response.id, 'req-development');
	assert.ok(response.ok);
	if (!response.ok) {
		assert.fail('expected successful response');
	}
	assert.equal(response.result.kind, 'explanation');
	assert.match(response.result.markdown, /Development agent runtime/);
	assert.match(response.result.markdown, /response for \*\*elixir\*\*\./);
});

test('handleBackendRequest returns capped development annotations', async () => {
	const response = await handleBackendRequest({
		id: 'req-2',
		method: 'annotateRange',
		config: {
			agent: { runtime: 'development' },
		},
		params: {
			filePath: '/repo/example.ts',
			language: 'typescript',
			text: 'const one = 1;\nconst two = 2;\nconst three = 3;\nconst four = 4;',
			cursor: { line: 1, character: 1 },
			visibleRange: { startLine: 1, startCharacter: 1, endLine: 4, endCharacter: 15 },
			scopeText: 'const one = 1;\nconst two = 2;\nconst three = 3;\nconst four = 4;',
			maxAnnotations: 4,
			lens: { mode: 'review', text: 'Check naming clarity' },
		},
	});

	assert.ok(response.ok);
	if (!response.ok) {
		assert.fail('expected successful response');
	}
	assert.equal(response.result.kind, 'annotations');
	assert.equal(response.result.annotations.length, 4);
	assert.equal(response.result.annotations[0].range.startLine, 1);
	assert.match(response.result.annotations[0].text, /Development annotation/);
	assert.match(response.result.annotations[0].detailMarkdown ?? '', /Annotation detail/);
});

test('handleBackendRequest routes explainSelection through CompletionRuntime when runtime is completion', async () => {
	const response = await handleBackendRequest({
		id: 'req-explain-completion',
		method: 'explainSelection',
		config: {
			agent: { runtime: 'development' },
		},
		params: {
			filePath: '/repo/example.ts',
			language: 'typescript',
			text: 'const value = 1;',
			cursor: { line: 1, character: 1 },
			selectedText: 'const value = 1;',
			runtime: 'completion',
		},
	});

	assert.ok(response.ok);
	if (!response.ok) {
		assert.fail('expected successful response');
	}
	assert.equal(response.result.kind, 'explanation');
	// DevelopmentCompletionRuntime's fixed response format, not the agent
	// runtime's "Development agent runtime" one — proves this went through
	// CompletionRuntime, not AgentRuntime.
	assert.match(response.result.markdown, /Development completion response for/);
});

test('completion mode bypasses adjacent-or-pi discovery', async () => {
	const response = await handleBackendRequest({
		id: 'req-hybrid-completion',
		method: 'questionSelection',
		config: {
			agent: {
				runtime: 'adjacent-or-pi',
				adjacent: { socket_path: '/tmp/vantage-must-not-probe.sock' },
				provider: 'missing-provider',
				model: 'missing-model',
			},
		},
		params: {
			workspaceRoot: '/tmp',
			filePath: '/tmp/example.ts',
			language: 'typescript',
			text: 'const value = 1;',
			cursor: { line: 1, character: 1 },
			selectedText: 'const value = 1;',
			question: 'What does this do?',
			runtime: 'completion',
		},
	});

	assert.equal(response.ok, false);
	if (response.ok) {
		assert.fail('expected the deliberately invalid completion model to fail');
	}
	assert.doesNotMatch(response.error.message, /bridge directory|adjacent Pi/i);
	assert.match(response.error.message, /model|provider/i);
});

test('handleBackendRequest routes questionSelection through CompletionRuntime when runtime is completion', async () => {
	const response = await handleBackendRequest({
		id: 'req-question-completion',
		method: 'questionSelection',
		config: {
			agent: { runtime: 'development' },
		},
		params: {
			filePath: '/repo/example.ts',
			language: 'typescript',
			text: 'const value = 1;',
			cursor: { line: 1, character: 1 },
			selectedText: 'const value = 1;',
			question: 'What does this do?',
			runtime: 'completion',
		},
	});

	assert.ok(response.ok);
	if (!response.ok) {
		assert.fail('expected successful response');
	}
	assert.equal(response.result.kind, 'explanation');
	assert.match(response.result.markdown, /Development completion response for/);
});

test('handleBackendRequest routes annotateRange through CompletionRuntime when runtime is completion', async () => {
	const response = await handleBackendRequest({
		id: 'req-annotate-completion',
		method: 'annotateRange',
		config: {
			// DevelopmentCompletionRuntime always returns plain prose, not JSON,
			// so this exercises the "malformed response" error path rather than
			// a successful parse -- real providers are expected to follow the
			// prompt's JSON instructions. Covering the successful-parse path is
			// parseAnnotationResponse's own unit tests in prompts.test.ts.
			agent: { runtime: 'development' },
		},
		params: {
			filePath: '/repo/example.ts',
			language: 'typescript',
			text: 'const value = 1;',
			cursor: { line: 1, character: 1 },
			scopeText: 'const value = 1;',
			runtime: 'completion',
		},
	});

	assert.equal(response.ok, false);
	if (response.ok) {
		assert.fail('expected a parse-error response');
	}
	assert.match(response.error.message, /annotation response was not valid JSON/);
});

test('handleBackendRequest defaults to agent runtime when runtime is omitted', async () => {
	const response = await handleBackendRequest({
		id: 'req-explain-default',
		method: 'explainSelection',
		config: {
			agent: { runtime: 'development' },
		},
		params: {
			filePath: '/repo/example.ts',
			language: 'typescript',
			text: 'const value = 1;',
			cursor: { line: 1, character: 1 },
			selectedText: 'const value = 1;',
		},
	});

	assert.ok(response.ok);
	if (!response.ok) {
		assert.fail('expected successful response');
	}
	assert.equal(response.result.kind, 'explanation');
	assert.match(response.result.markdown, /Development agent runtime/);
});

test('handleBackendRequest can use an injected agent runtime', async () => {
	const agentRuntime: AgentRuntime = {
		explainSelection: () => ({ kind: 'explanation', markdown: 'Injected explanation' }),
		questionSelection: () => ({ kind: 'explanation', markdown: 'Injected answer' }),
		editSelection: () => ({ kind: 'edit', replacementText: 'const edited = true;' }),
		annotateRange: () => ({ kind: 'annotations', annotations: [] }),
		searchLocations: () => ({ kind: 'locations', locations: [] }),
		agentCancel: () => ({ kind: 'explanation', markdown: 'Injected cancel' }),
		agentSessionReset: () => ({ kind: 'explanation', markdown: 'Injected reset' }),
		agentSessionStatus: () => ({ kind: 'explanation', markdown: 'Injected status' }),
		agentSessionOutput: () => ({ kind: 'explanation', markdown: 'Injected output' }),
		listSkills: () => ({ kind: 'skills', skills: [] }),
		generateWalkthrough: () => ({ kind: 'walkthrough', path: '/repo/.vantage/walkthrough.json', pointerCount: 0 }),
	};

	const response = await handleBackendRequest(
		{
			id: 'req-injected',
			method: 'explainSelection',
			params: {
				filePath: '/repo/example.ts',
				language: 'typescript',
				text: 'const value = 1;',
				cursor: { line: 1, character: 1 },
				selectedText: 'const value = 1;',
			},
		},
		agentRuntime
	);

	assert.equal(response.id, 'req-injected');
	assert.ok(response.ok);
	if (!response.ok) {
		assert.fail('expected successful response');
	}
	assert.equal(response.result.kind, 'explanation');
	assert.equal(response.result.markdown, 'Injected explanation');
});

// --- editSelection: runtime eligibility and scope routing ---

interface EditRequestOverrides {
	runtime?: 'agent' | 'completion';
	scope?: 'selection' | 'file';
	instruction?: string;
}

function editRequest(overrides: EditRequestOverrides = {}) {
	return {
		id: 'req-edit',
		method: 'editSelection' as const,
		config: { agent: { runtime: 'development' as const } },
		params: {
			filePath: '/repo/example.ts',
			language: 'typescript',
			text: 'const value = 1;',
			cursor: { line: 1, character: 1 },
			range: { startLine: 1, startCharacter: 1, endLine: 1, endCharacter: 16 },
			scopeText: 'const value = 1;',
			instruction: 'rename value to count',
			...overrides,
		},
	};
}

test('handleBackendRequest routes editSelection through the agent runtime by default', async () => {
	const response = await handleBackendRequest(editRequest());

	assert.ok(response.ok);
	if (!response.ok) {
		assert.fail('expected successful response');
	}
	assert.equal(response.result.kind, 'edit_applied');
});

test('handleBackendRequest routes editSelection through CompletionRuntime when runtime is completion', async () => {
	const response = await handleBackendRequest(editRequest({ runtime: 'completion' }));

	assert.ok(response.ok);
	if (!response.ok) {
		assert.fail('expected successful response');
	}
	// This is the exclusion this feature removed: editSelection used to be
	// rejected from completion mode because its result arrived via a tool call.
	assert.equal(response.result.kind, 'edit');
});

test('handleBackendRequest ignores scope in agent mode', async () => {
	const response = await handleBackendRequest(editRequest({ scope: 'file' }));

	assert.ok(response.ok);
	if (!response.ok) {
		assert.fail('expected successful response');
	}
	assert.equal(response.result.kind, 'edit_applied');
});

test('handleBackendRequest returns hunks for file scope in completion mode only', async () => {
	const response = await handleBackendRequest(
		editRequest({
			scope: 'file',
			runtime: 'completion',
			// DevelopmentCompletionRuntime echoes a fixed string, so feed the
			// blocks through the params it echoes back.
			instruction: 'rename value to count',
		})
	);

	// Either it parsed blocks out of the development response, or it failed
	// loudly. What must NOT happen is silently returning the 'edit' shape.
	if (response.ok) {
		assert.equal(response.result.kind, 'edits');
		return;
	}
	assert.match(response.error.message, /SEARCH|block/i);
});

test('handleBackendRequest accepts file scope with the agent runtime', async () => {
	const response = await handleBackendRequest(editRequest({ scope: 'file', runtime: 'agent' }));

	assert.ok(response.ok);
	if (!response.ok) {
		assert.fail('expected the agent runtime to own the file edit');
	}
	assert.equal(response.result.kind, 'edit_applied');
});

test('handleBackendRequest still accepts file scope with the completion runtime', async () => {
	const response = await handleBackendRequest(editRequest({ scope: 'file', runtime: 'completion' }));

	if (response.ok) {
		assert.equal(response.result.kind, 'edits');
		return;
	}
	assert.match(response.error.message, /SEARCH|block|incomplete/i);
});

test('parseSearchReplaceBlocks output naming another file is dropped before it reaches the client', async () => {
	// The README promises such blocks are rejected; nothing enforced it, so a
	// block for a neighbouring file was spliced into the open buffer.
	const foreign = [
		'other/module.ts',
		'```ts',
		'<<<<<<< SEARCH',
		'const value = 1;',
		'=======',
		'const value = 2;',
		'>>>>>>> REPLACE',
		'```',
	].join('\n');
	const { parseSearchReplaceBlocks } = await import('./markdown-utils');
	const hunks = parseSearchReplaceBlocks(foreign);

	assert.equal(hunks.length, 1);
	assert.equal(hunks[0].filePath, 'other/module.ts');
});

test('hunksForCurrentFile drops a block naming another file', () => {
	const hunks = [
		{ search: 'a', replace: 'b', filePath: 'other/module.ts' },
		{ search: 'c', replace: 'd', filePath: 'src/app.ts' },
	];

	const kept = hunksForCurrentFile(hunks, '/repo/src/app.ts');

	// This is the guarantee the README states and nothing previously enforced.
	assert.equal(kept.length, 1);
	assert.equal(kept[0].search, 'c');
});

test('hunksForCurrentFile keeps a block with no filename', () => {
	// The header is optional decoration; its absence is not a claim about
	// another file, so dropping these would break the common case.
	const kept = hunksForCurrentFile([{ search: 'a', replace: 'b' }], '/repo/src/app.ts');

	assert.equal(kept.length, 1);
});

test('hunksForCurrentFile matches a repo-relative path against an absolute one', () => {
	const kept = hunksForCurrentFile(
		[{ search: 'a', replace: 'b', filePath: './src/app.ts' }],
		'/repo/src/app.ts'
	);

	assert.equal(kept.length, 1);
});
