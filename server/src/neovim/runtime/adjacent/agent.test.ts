import * as test from 'node:test';
import * as assert from 'node:assert/strict';
import type { AgentSessionEventListener } from '@earendil-works/pi-coding-agent';
import { AdjacentAgentRuntime } from './agent';
import { PiAgenticRuntime } from '../pi/agent';
import type { ForkedSession } from './session';
import { CodingAgentSessionStore } from '../pi/session-store';
import { createAgentRuntimeFromConfig } from '../agent-factory';
import { BackendRequestConfigSchema } from '../../protocol';

const params = {
	workspaceRoot: '/repo',
	filePath: '/repo/example.ts',
	language: 'typescript',
	text: 'const value = 1;',
	selectedText: 'const value = 1;',
	range: { startLine: 1, startCharacter: 1, endLine: 1, endCharacter: 17 },
	cursor: { line: 1, character: 1 },
};

function fakeFork() {
	let listener: AgentSessionEventListener | undefined;
	const prompts: string[] = [];
	const tools: string[] = [];
	const state = { disposed: 0, aborted: 0, prompts, tools };
	const fork: ForkedSession = {
		source: { sessionId: 'parent', leafId: 'leaf', provider: 'openai', model: 'gpt-4o-mini' },
		session: {
			setActiveToolsByName(tools) {
				state.tools = tools;
			},
			subscribe(handler) {
				listener = handler;
				return () => {
					listener = undefined;
				};
			},
			async prompt(prompt) {
				state.prompts.push(prompt);
				listener?.({
					type: 'message_end',
					message: {
						role: 'assistant',
						content: [{ type: 'text', text: 'An explanation.' }],
						api: 'test',
						provider: 'openai',
						model: 'gpt-4o-mini',
						stopReason: 'stop',
						timestamp: 1,
						usage: {
							input: 0,
							output: 0,
							cacheRead: 0,
							cacheWrite: 0,
							totalTokens: 0,
							cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
						},
					},
				});
			},
			async abort() {
				state.aborted++;
			},
			dispose() {
				state.disposed++;
			},
		},
	};
	return { fork, state };
}

test('factory and wire schema select adjacent without changing command contracts', async () => {
	const config = BackendRequestConfigSchema.parse({
		agent: { runtime: 'adjacent', adjacent: { socket_path: '/tmp/private/pi.sock' } },
	});
	assert.equal(config.agent?.adjacent?.socket_path, '/tmp/private/pi.sock');
	const runtime = createAgentRuntimeFromConfig(config);
	assert.ok(runtime instanceof AdjacentAgentRuntime);
	assert.ok(!(runtime instanceof PiAgenticRuntime));
	assert.match((await runtime.agentSessionStatus()).markdown, /fresh fork/);
});

test('adjacent runtime owns fork configuration and passes the shared command tool policy', async () => {
	const created = fakeFork();
	created.fork.source.parentBusy = true;
	const store = new CodingAgentSessionStore();
	const auth = { path: '/tmp/pi-auth.json' };
	const runtime = new AdjacentAgentRuntime({
		store,
		socketPath: '/tmp/private/pi.sock',
		auth,
		forkSession: async (root, customTools, tools, signal, socketPath, configuredAuth) => {
			assert.equal(root, params.workspaceRoot);
			assert.equal(socketPath, '/tmp/private/pi.sock');
			assert.deepEqual(configuredAuth, auth);
			assert.deepEqual(tools, ['read', 'grep', 'find', 'ls']);
			assert.ok(customTools.some((tool) => tool.name === 'submit_annotations'));
			assert.equal(signal.aborted, false);
			return created.fork;
		},
	});
	assert.equal((await runtime.explainSelection(params)).markdown, 'An explanation.');
	assert.equal(created.state.disposed, 1);
	assert.match(store.renderOutput(false), /Parent busy; using latest completed turn/);
});

test('each command gets a fresh disposed fork, standard tools, and shared output handling', async () => {
	const store = new CodingAgentSessionStore();
	const forks: ReturnType<typeof fakeFork>[] = [];
	const runtime = new AdjacentAgentRuntime({
		store,
		forkSession: async () => {
			const created = fakeFork();
			forks.push(created);
			return created.fork;
		},
	});
	assert.equal((await runtime.explainSelection(params)).markdown, 'An explanation.');
	assert.equal((await runtime.questionSelection({ ...params, question: 'why?' })).markdown, 'An explanation.');
	await runtime.editSelection({ ...params, scopeText: params.text, instruction: 'rename value' });
	await assert.rejects(
		runtime.annotateRange({ ...params, scopeText: params.text, maxAnnotations: 1 }),
		/did not receive submit_annotations/,
	);
	assert.deepEqual(forks.map(({ state }) => state.tools), [
		['read', 'grep', 'find', 'ls'],
		['read', 'grep', 'find', 'ls'],
		['read', 'grep', 'find', 'ls', 'edit', 'write'],
		['submit_annotations'],
	]);
	assert.ok(forks.every(({ state }) => state.disposed === 1 && state.prompts.length === 1));
	assert.equal(store.status().session, undefined, 'forks never enter the persistent buddy store');
	assert.match(store.renderOutput(false), /Forked Pi parent at leaf/);
	assert.match(store.renderOutput(false), /An explanation/);
	await runtime.agentSessionReset();
	assert.equal(store.status().outputHistoryCount, 0);
});

test('cancel during fork setup prevents prompting, disposes late sessions, and reserves the request slot', async () => {
	const store = new CodingAgentSessionStore();
	const created = fakeFork();
	let release!: (fork: ForkedSession) => void;
	const gate = new Promise<ForkedSession>((resolve) => {
		release = resolve;
	});
	let markStarted!: () => void;
	const started = new Promise<void>((resolve) => {
		markStarted = resolve;
	});
	const runtime = new AdjacentAgentRuntime({
		store,
		forkSession: async () => {
			markStarted();
			return gate;
		},
	});
	const pending = runtime.explainSelection(params);
	const rejected = assert.rejects(pending, /cancelled/);
	await started;
	await runtime.agentCancel();
	await assert.rejects(runtime.questionSelection({ ...params, question: 'another request' }), /already running/);
	release(created.fork);
	await rejected;
	assert.equal(created.state.prompts.length, 0);
	assert.equal(created.state.disposed, 1);
	assert.equal(store.status().active, undefined);
	assert.match(store.renderOutput(false), /cancelled/);
});

test('annotation cancellation aborts only the fork and disposes it', async () => {
	const created = fakeFork();
	let release!: () => void;
	const prompt = new Promise<void>((resolve) => {
		release = resolve;
	});
	let markStarted!: () => void;
	const started = new Promise<void>((resolve) => {
		markStarted = resolve;
	});
	created.fork.session.prompt = async () => {
		markStarted();
		await prompt;
	};
	created.fork.session.abort = async () => {
		created.state.aborted++;
		release();
	};
	const store = new CodingAgentSessionStore();
	const runtime = new AdjacentAgentRuntime({ store, forkSession: async () => created.fork });
	const pending = runtime.annotateRange({ ...params, scopeText: params.text });
	const rejected = assert.rejects(pending, /cancelled/);
	await started;
	await runtime.agentCancel();
	await rejected;
	assert.equal(created.state.aborted, 1);
	assert.equal(created.state.disposed, 1);
	assert.equal(store.status().active, undefined);
});

test('command timeout also covers pending fork setup', async () => {
	const store = new CodingAgentSessionStore();
	const runtime = new AdjacentAgentRuntime({
		store,
		commandOptions: { explain: { options: { timeoutMs: 10 } } },
		forkSession: async (_root, _customTools, _tools, signal) =>
			new Promise<ForkedSession>((_resolve, reject) => {
				signal.addEventListener('abort', () => reject(signal.reason), { once: true });
			}),
	});
	await assert.rejects(runtime.explainSelection(params), /cancelled/);
	assert.equal(store.status().active, undefined);
	assert.match(store.renderOutput(false), /cancelled/);
});

test('pre-aborted requests do not fork; setup failures finish output and release the slot', async () => {
	let calls = 0;
	const store = new CodingAgentSessionStore();
	const runtime = new AdjacentAgentRuntime({
		store,
		forkSession: async () => {
			calls++;
			throw new Error('bridge disconnected');
		},
	});
	const controller = new AbortController();
	controller.abort(new Error('already cancelled'));
	await assert.rejects(runtime.explainSelection(params, { signal: controller.signal }), /already cancelled/);
	assert.equal(calls, 0);
	await assert.rejects(runtime.explainSelection(params), /bridge disconnected/);
	assert.equal(store.status().active, undefined);
	assert.match(store.renderOutput(false), /failed/);
});
