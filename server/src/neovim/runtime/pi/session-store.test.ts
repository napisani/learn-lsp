import * as test from 'node:test';
import * as assert from 'node:assert/strict';
import { CodingAgentSessionStore, type AgentSessionHandle } from './session-store';

function fakeSession(): AgentSessionHandle {
	return {
		setActiveToolsByName() {},
		subscribe() {
			return () => {};
		},
		async prompt() {},
		async abort() {},
		dispose() {},
	};
}

test('status() reports createdAt once a session is created', async () => {
	const store = new CodingAgentSessionStore();
	const before = Date.now();

	await store.getOrCreate({
		workspaceRoot: '/tmp/workspace',
		provider: 'openai',
		model: 'gpt-4o-mini',
		createSession: async () => fakeSession(),
	});

	const status = store.status();
	assert.ok(status.session);
	assert.ok(status.session!.createdAt >= before);
});

test('status() excludes transient (annotation) entries from session turns and last command', () => {
	const store = new CodingAgentSessionStore();

	store.startOutputEntry({
		kind: 'explain',
		transient: false,
		provider: 'openai',
		model: 'gpt-4o-mini',
		userSummary: 'explain this',
		prompt: 'explain',
	});
	store.startOutputEntry({
		kind: 'annotate',
		transient: true,
		provider: 'openai',
		model: 'gpt-4o-mini',
		userSummary: 'annotate this',
		prompt: 'annotate',
	});

	const status = store.status();
	assert.equal(status.outputHistoryCount, 2, 'total history includes transient entries');
	assert.equal(status.sessionTurnCount, 1, 'session turns excludes the transient annotate entry');
	assert.equal(status.lastCommandKind, 'explain', 'last command skips the later transient entry');
});

test('status() reports the configured history limit', () => {
	const store = new CodingAgentSessionStore();
	store.setHistoryLimit(3);

	assert.equal(store.status().historyLimit, 3);
});
