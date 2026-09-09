import * as test from 'node:test';
import * as assert from 'node:assert/strict';
import { createCompletionRuntimeFromConfig } from './completion-factory';
import { DevelopmentCompletionRuntime } from './development/completion';
import { PiCompletionRuntime } from './pi/completion';

test('createCompletionRuntimeFromConfig returns DevelopmentCompletionRuntime for development runtime', () => {
	const runtime = createCompletionRuntimeFromConfig({
		agent: { runtime: 'development' },
	});
	assert.ok(runtime instanceof DevelopmentCompletionRuntime);
});

test('createCompletionRuntimeFromConfig returns PiCompletionRuntime for pi runtime', () => {
	const runtime = createCompletionRuntimeFromConfig({
		agent: { provider: 'openai', model: 'gpt-4o-mini' },
	});
	assert.ok(runtime instanceof PiCompletionRuntime);
});

test('createCompletionRuntimeFromConfig defaults to PiCompletionRuntime with pi defaults', () => {
	const runtime = createCompletionRuntimeFromConfig({});
	assert.ok(runtime instanceof PiCompletionRuntime);
});

test('completion runtime keeps its own freeform options without Vantage defaults', () => {
	const runtime = createCompletionRuntimeFromConfig({
		agent: {
			provider: 'openai-codex',
			model: 'gpt-5.3-codex',
			options: { temperature: 0.1 },
		},
		completion: {
			options: {
				maxTokens: 777,
				reasoning: 'high',
				customOption: 'kept',
			},
		},
	});

	assert.ok(runtime instanceof PiCompletionRuntime);
	if (!(runtime instanceof PiCompletionRuntime)) {
		assert.fail('expected PiCompletionRuntime');
	}
	assert.deepEqual(runtime.options, {
		maxTokens: 777,
		reasoning: 'high',
		customOption: 'kept',
	});
});

test('DevelopmentCompletionRuntime returns deterministic completion text', async () => {
	const runtime = new DevelopmentCompletionRuntime();
	const result = await runtime.complete({ prompt: 'hello world' });
	assert.equal(result.text, 'Development completion response for: hello world');
	assert.equal(result.model, 'development');
	assert.equal(result.provider, 'development');
});