import * as test from 'node:test';
import * as assert from 'node:assert/strict';
import type { AssistantMessage } from '@earendil-works/pi-ai';
import { createModelTarget } from '../pi/model-target';
import { SessionSnapshots } from './extension';

function toolCallMessage(): AssistantMessage {
	return {
		role: 'assistant',
		content: [{ type: 'toolCall', id: 'read-1', name: 'read', arguments: { path: 'example.ts' } }],
		api: 'openai-responses', provider: 'openai', model: 'gpt-4o-mini', stopReason: 'toolUse', timestamp: 2,
		usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
	};
}

test('busy snapshots advance only after complete turns and never include partial tool sequences', async () => {
	const { piAgent, model } = await createModelTarget({ provider: 'openai', model: 'gpt-4o-mini' });
	const parent = piAgent.SessionManager.inMemory('/tmp');
	let idle = true;
	let pending = false;
	const ctx = {
		cwd: '/tmp', model, thinkingLevel: 'low' as const, sessionManager: parent,
		isIdle: () => idle, hasPendingMessages: () => pending,
	};
	const snapshots = new SessionSnapshots();
	// The baseline before the first turn is an empty but valid conversation.
	const initial = snapshots.read(ctx);
	assert.equal(initial.entryCount, 0);
	idle = false;
	parent.appendMessage({ role: 'user', content: 'read the file', timestamp: 1 });
	parent.appendMessage(toolCallMessage());
	assert.equal(snapshots.read(ctx).branch, initial.branch);
	assert.equal(snapshots.read(ctx).parentBusy, true);
	parent.appendMessage({
		role: 'toolResult', toolCallId: 'read-1', toolName: 'read', content: [{ type: 'text', text: 'file contents' }],
		isError: false, timestamp: 3,
	});
	// Mirrors turn_end: the tool batch is complete even though Pi keeps working.
	snapshots.capture(ctx);
	const completed = snapshots.read(ctx);
	assert.equal(completed.entryCount, 3);
	assert.equal(completed.leafId, parent.getLeafId());
	assert.match(completed.branch, /file contents/);
	parent.appendMessage({ ...toolCallMessage(), timestamp: 4 });
	assert.equal(snapshots.read(ctx).branch, completed.branch);
	// Pending continuations must also use the cached snapshot.
	idle = true;
	pending = true;
	assert.equal(snapshots.read(ctx).branch, completed.branch);
	// Navigating back while idle replaces the cached branch, not just its leaf label.
	pending = false;
	parent.resetLeaf();
	assert.equal(snapshots.read(ctx).entryCount, 0);
	assert.equal(snapshots.read(ctx).parentBusy, false);
});

test('never serves a snapshot from another session or an unobserved busy turn', async () => {
	const { piAgent, model } = await createModelTarget({ provider: 'openai', model: 'gpt-4o-mini' });
	const parent = piAgent.SessionManager.inMemory('/tmp');
	const ctx = {
		cwd: '/tmp', model, thinkingLevel: 'off' as const, sessionManager: parent,
		isIdle: () => false, hasPendingMessages: () => false,
	};
	const snapshots = new SessionSnapshots();
	assert.throws(() => snapshots.read(ctx), /no completed turn snapshot/);
	snapshots.capture(ctx);
	assert.equal(snapshots.read(ctx).entryCount, 0);
	parent.newSession();
	assert.throws(() => snapshots.read(ctx), /no completed turn snapshot/);
});
