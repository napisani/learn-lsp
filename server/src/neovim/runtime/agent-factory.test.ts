import * as test from 'node:test';
import * as assert from 'node:assert/strict';
import type { AgentSessionEvent, AgentSessionEventListener } from '@earendil-works/pi-coding-agent';
import { createAgentRuntimeFromConfig } from './agent-factory';
import { DevelopmentAgentRuntime } from './development/agent';
import { PiAgenticRuntime, loadCodingAgentModuleForTest } from './pi/agent';
import type { AgentSessionStore, GetOrCreateSessionOptions } from './pi/session-store';

/** Builds a minimal, validly-typed `message_end` event carrying assistant text. */
function messageEndEvent(text: string): AgentSessionEvent {
	return {
		type: 'message_end',
		message: {
			role: 'assistant',
			content: [{ type: 'text', text }],
			api: 'test-api',
			provider: 'test-provider',
			model: 'test-model',
			usage: {
				input: 0,
				output: 0,
				cacheRead: 0,
				cacheWrite: 0,
				totalTokens: 0,
				cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
			},
			stopReason: 'stop',
			timestamp: Date.now(),
		},
	};
}

test('createAgentRuntimeFromConfig defaults to Pi openai/gpt-4o-mini', () => {
	const runtime = createAgentRuntimeFromConfig();

	assert.ok(runtime instanceof PiAgenticRuntime);
	assert.equal(runtime.provider, 'openai');
	assert.equal(runtime.model, 'gpt-4o-mini');
	assert.deepEqual(runtime.options, {});
});

test('createAgentRuntimeFromConfig passes model target, agent options, and command options', () => {
	const runtime = createAgentRuntimeFromConfig({
		agent: {
			provider: 'anthropic',
			model: 'claude-sonnet-test',
			auth: {
				path: '/tmp/pi-auth.json',
			},
			options: {
				apiKey: 'sk-config',
				reasoning: 'medium',
				temperature: 0.2,
				maxTokens: 2048,
				timeoutMs: 900_000,
				maxRetries: 1,
				maxRetryDelayMs: 5000,
				metadata: { source: 'vantage-test' },
				headers: { 'x-test': 'yes' },
			},
		},
		commands: {
			question: {
				options: {
					maxTokens: 1536,
				},
			},
			edit: {
				options: {
					timeoutMs: 60_000,
				},
			},
			annotate: {
				options: {
					maxTokens: 128,
					timeoutMs: 12_345,
				},
			},
		},
	});

	assert.ok(runtime instanceof PiAgenticRuntime);
	assert.equal(runtime.provider, 'anthropic');
	assert.equal(runtime.model, 'claude-sonnet-test');
	assert.deepEqual(runtime.auth, {
		path: '/tmp/pi-auth.json',
	});
	assert.deepEqual(runtime.options, {
		apiKey: 'sk-config',
		reasoning: 'medium',
		temperature: 0.2,
		maxTokens: 2048,
		timeoutMs: 900_000,
		maxRetries: 1,
		maxRetryDelayMs: 5000,
		metadata: { source: 'vantage-test' },
		headers: { 'x-test': 'yes' },
	});
	assert.deepEqual(runtime.commandOptions.annotate?.options, {
		maxTokens: 128,
		timeoutMs: 12_345,
	});
	assert.deepEqual(runtime.commandOptions.question?.options, {
		maxTokens: 1536,
	});
	assert.deepEqual(runtime.commandOptions.edit?.options, {
		timeoutMs: 60_000,
	});
});

test('PiAgenticRuntime loads ESM Pi SDK without CommonJS require fallback', async () => {
	const piAgent = await loadCodingAgentModuleForTest();

	assert.ok(piAgent.createAgentSession instanceof Function);
	assert.ok(piAgent.defineTool instanceof Function);
});

test('PiAgenticRuntime acknowledges agent-owned native edits', async () => {
	let listener: AgentSessionEventListener | undefined;
	const fakeSession = {
		setActiveToolsByName() {},
		subscribe(value: AgentSessionEventListener) {
			listener = value;
			return () => {
				listener = undefined;
			};
		},
		async prompt() {
			listener?.(messageEndEvent('```lua\nconst count = 1;\n```'));
		},
		async abort() {},
		dispose() {},
	};
	const fakeStore: AgentSessionStore = {
		async getOrCreate() {
			return fakeSession;
		},
		begin() {},
		end() {},
		async cancel() {
			return false;
		},
		async reset() {
			return false;
		},
		status() {
			return { outputHistoryCount: 0, historyLimit: 10, sessionTurnCount: 0 };
		},
		renderOutput() {
			return '';
		},
	};
	const runtime = new PiAgenticRuntime({ store: fakeStore });

	const edit = await runtime.editSelection({
		filePath: '/repo/example.ts',
		language: 'typescript',
		text: 'const value = 1;',
		cursor: { line: 1, character: 1 },
		range: { startLine: 1, startCharacter: 1, endLine: 1, endCharacter: 16 },
		scopeText: 'const value = 1;',
		instruction: 'rename value to count',
	});

	assert.equal(edit.kind, 'edit_applied');
	assert.equal(edit.kind === 'edit_applied', true);
});

test('PiAgenticRuntime falls back to assistant JSON when submit_search_results is not called', async () => {
	let listener: AgentSessionEventListener | undefined;
	const fakeSession = {
		setActiveToolsByName() {},
		subscribe(value: AgentSessionEventListener) {
			listener = value;
			return () => {
				listener = undefined;
			};
		},
		async prompt() {
			listener?.(messageEndEvent(JSON.stringify({ locations: [{ filePath: 'package.json', startLine: 1, startCharacter: 1, explanation: 'Defines the package metadata.' }] })));
		},
		async abort() {},
		dispose() {},
	};
	const fakeStore: AgentSessionStore = {
		async getOrCreate() {
			return fakeSession;
		},
		begin() {},
		end() {},
		async cancel() {
			return false;
		},
		async reset() {
			return false;
		},
		status() {
			return { outputHistoryCount: 0, historyLimit: 10, sessionTurnCount: 0 };
		},
		renderOutput() {
			return '';
		},
	};
	const runtime = new PiAgenticRuntime({ store: fakeStore });

	const result = await runtime.searchLocations({
		workspaceRoot: process.cwd(),
		filePath: `${process.cwd()}/package.json`,
		language: 'json',
		text: '{"name":"vantage.nvim"}',
		cursor: { line: 1, character: 1 },
		query: 'find value',
	});

	assert.equal(result.locations[0].filePath, 'package.json');
});

test('PiAgenticRuntime keeps native edit tools live when an explain command creates the singleton session first', async () => {
	let listener: AgentSessionEventListener | undefined;
	const fakeSession = {
		setActiveToolsByName() {},
		subscribe(value: AgentSessionEventListener) {
			listener = value;
			return () => {
				listener = undefined;
			};
		},
		async prompt() {
			listener?.(messageEndEvent('Pi completed the requested edit.'));
		},
		async abort() {},
		dispose() {},
	};
	const fakeStore: AgentSessionStore = {
		async getOrCreate() {
			return fakeSession;
		},
		begin() {},
		end() {},
		async cancel() {
			return false;
		},
		async reset() {
			return false;
		},
		status() {
			return { outputHistoryCount: 0, historyLimit: 10, sessionTurnCount: 0 };
		},
		renderOutput() {
			return '';
		},
	};
	const runtime = new PiAgenticRuntime({ store: fakeStore });
	const baseParams = {
		filePath: '/repo/example.ts',
		language: 'typescript',
		text: 'const value = 1;',
		cursor: { line: 1, character: 1 },
	};

	await runtime.explainSelection({
		...baseParams,
		selectedText: 'const value = 1;',
	});
	const edit = await runtime.editSelection({
		...baseParams,
		range: { startLine: 1, startCharacter: 1, endLine: 1, endCharacter: 16 },
		scopeText: 'const value = 1;',
		instruction: 'rename value to count',
	});

	assert.equal(edit.kind, 'edit_applied');
	assert.equal(edit.kind === 'edit_applied', true);
});

test('PiAgenticRuntime passes singleton session inputs and command-specific active tools', async () => {
	let listener: AgentSessionEventListener | undefined;
	const activeToolSets: string[][] = [];
	let getOrCreateOptions: GetOrCreateSessionOptions | undefined;
	const fakeSession = {
		setActiveToolsByName(tools: string[]) {
			activeToolSets.push(tools);
		},
		subscribe(value: AgentSessionEventListener) {
			listener = value;
			return () => {
				listener = undefined;
			};
		},
		async prompt(prompt: string) {
			let text = 'markdown response';
			if (prompt.includes('User edit instruction:')) {
				text = 'const count = 1;';
			} else if (prompt.includes('User search request:')) {
				text = JSON.stringify({ locations: [{ filePath: 'package.json', startLine: 1, startCharacter: 1, explanation: 'Defines the package metadata.' }] });
			}
			listener?.(messageEndEvent(text));
		},
		async abort() {},
		dispose() {},
	};
	const fakeStore: AgentSessionStore = {
		async getOrCreate(options) {
			getOrCreateOptions = options;
			return fakeSession;
		},
		begin() {},
		end() {},
		async cancel() {
			return false;
		},
		async reset() {
			return false;
		},
		status() {
			return { outputHistoryCount: 0, historyLimit: 10, sessionTurnCount: 0 };
		},
		renderOutput() {
			return '';
		},
	};
	const runtime = new PiAgenticRuntime({
		provider: 'anthropic',
		model: 'claude-test',
		auth: { path: '/tmp/auth.json' },
		options: { apiKey: 'explicit-key', reasoning: 'medium' },
		store: fakeStore,
	});
	const baseParams = {
		workspaceRoot: process.cwd(),
		filePath: `${process.cwd()}/package.json`,
		language: 'json',
		text: '{"name":"vantage.nvim"}',
		cursor: { line: 1, character: 1 },
	};

	await runtime.explainSelection({ ...baseParams, selectedText: baseParams.text });
	await runtime.editSelection({
		...baseParams,
		range: { startLine: 1, startCharacter: 1, endLine: 1, endCharacter: 24 },
		scopeText: baseParams.text,
		instruction: 'rename value to count',
	});
	await runtime.searchLocations({ ...baseParams, query: 'find package metadata' });

	assert.equal(getOrCreateOptions?.workspaceRoot, process.cwd());
	assert.equal(getOrCreateOptions?.provider, 'anthropic');
	assert.equal(getOrCreateOptions?.model, 'claude-test');
	assert.deepEqual(activeToolSets, [
		['read', 'grep', 'find', 'ls'],
		['read', 'grep', 'find', 'ls', 'edit', 'write'],
		['read', 'grep', 'find', 'ls', 'submit_search_results'],
	]);
});

test('createAgentRuntimeFromConfig keeps development runtime internal', () => {
	const runtime = createAgentRuntimeFromConfig({
		agent: {
			runtime: 'development',
		},
	});

	assert.ok(runtime instanceof DevelopmentAgentRuntime);
});
