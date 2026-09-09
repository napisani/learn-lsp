import * as test from 'node:test';
import * as assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { importPiCodingAgent } from '../pi/module';
import { createModelTarget } from '../pi/model-target';
import { SessionSnapshots } from './extension';
import { forkAdjacentSession } from './session';
import { bridgeSocketPath, requestBridge, startBridge } from './transport';

test('forks the active native branch, preserving compaction and leaving the parent untouched', async (t) => {
	const root = fs.mkdtempSync('/tmp/vantage-fork-test-');
	t.after(() => fs.rmSync(root, { recursive: true, force: true }));
	const pi = await importPiCodingAgent();
	const modelRuntime = await pi.ModelRuntime.create();
	const model = modelRuntime.getModel('openai', 'gpt-4o-mini');
	assert.ok(model);
	const parent = pi.SessionManager.inMemory(root);
	parent.appendMessage({ role: 'user', content: 'old context', timestamp: 1 });
	const kept = parent.appendMessage({ role: 'user', content: 'retained context', timestamp: 2 });
	parent.appendCompaction('the earlier conversation summary', kept, 100);
	const selected = parent.getLeafId();
	assert.ok(selected);
	parent.appendMessage({ role: 'user', content: 'wrong sibling branch', timestamp: 3 });
	parent.branch(selected);
	const before = JSON.stringify(parent.getEntries());
	let busy = false;
	const ctx = {
		cwd: root,
		model,
		thinkingLevel: 'low' as const,
		sessionManager: parent,
		isIdle: () => !busy,
		hasPendingMessages: () => false,
	};
	const socket = bridgeSocketPath(root, root);
	const snapshots = new SessionSnapshots();
	const close = await startBridge(socket, root, () => snapshots.read(ctx));
	t.after(close);
	const fork = await forkAdjacentSession(root, [], ['read'], new AbortController().signal, socket);
	t.after(() => {
		if (fork.session.sessionFile && fs.existsSync(fork.session.sessionFile)) {
			fork.session.dispose();
		}
	});
	assert.notEqual(fork.session.sessionId, parent.getSessionId());
	assert.match(fork.session.sessionFile ?? '', /vantage-adjacent-/);
	assert.equal(fs.statSync(fork.session.sessionFile!).mode & 0o777, 0o600);
	assert.deepEqual(fork.session.messages, parent.buildSessionContext().messages);
	assert.deepEqual(fork.session.getActiveToolNames(), ['read']);
	assert.equal(fork.source.leafId, selected);
	assert.equal(JSON.stringify(parent.getEntries()), before);
	assert.equal(parent.getLeafId(), selected);
	// Child mutations do not share objects with the live parent.
	fork.session.agent.state.messages = [];
	assert.notEqual(parent.buildSessionContext().messages.length, 0);
	parent.appendMessage({ role: 'user', content: 'new parent turn', timestamp: 4 });
	const newer = await forkAdjacentSession(root, [], ['read'], new AbortController().signal, socket);
	t.after(() => newer.session.dispose());
	assert.deepEqual(newer.session.messages, parent.buildSessionContext().messages);
	assert.notEqual(newer.session.sessionId, fork.session.sessionId);
	busy = true;
	parent.appendMessage({ role: 'user', content: 'unfinished next request', timestamp: 5 });
	const liveLeaf = parent.getLeafId();
	const whileBusy = await forkAdjacentSession(root, [], ['read'], new AbortController().signal, socket);
	const whileBusyFile = whileBusy.session.sessionFile;
	t.after(() => {
		if (whileBusyFile && fs.existsSync(whileBusyFile)) {
			whileBusy.session.dispose();
		}
	});
	assert.deepEqual(whileBusy.session.messages, newer.session.messages);
	assert.equal(whileBusy.source.leafId, newer.source.leafId);
	assert.equal(whileBusy.source.parentBusy, true);
	assert.notEqual(whileBusy.session.sessionId, newer.session.sessionId);
	assert.equal(parent.getLeafId(), liveLeaf);
	whileBusy.session.dispose();
	assert.equal(fs.existsSync(whileBusyFile!), false);
});

test('Pi loads the extension source and owns bridge startup, reload, and shutdown', async (t) => {
	const root = fs.mkdtempSync('/tmp/vantage-extension-test-');
	t.after(() => fs.rmSync(root, { recursive: true, force: true }));
	const { piAgent: pi, modelRuntime, model } = await createModelTarget({ provider: 'openai', model: 'gpt-4o-mini' });
	const loader = new pi.DefaultResourceLoader({
		cwd: root, agentDir: pi.getAgentDir(), noExtensions: true,
		additionalExtensionPaths: [path.resolve(__dirname, '../../../../src/neovim/runtime/adjacent/extension.ts')],
	});
	await loader.reload();
	assert.deepEqual(loader.getExtensions().errors, []);
	const extension = loader.getExtensions().extensions[0];
	assert.ok(extension.handlers.has('before_agent_start'));
	assert.ok(extension.handlers.has('turn_end'));
	const { session } = await pi.createAgentSession({
		cwd: root, modelRuntime, model, resourceLoader: loader,
		sessionManager: pi.SessionManager.inMemory(root),
	});
	const socket = bridgeSocketPath(root);
	t.after(async () => {
		await session.extensionRunner.emit({ type: 'session_shutdown', reason: 'quit' });
		session.dispose();
	});
	await session.bindExtensions({ mode: 'tui' });
	const response = await requestBridge(socket, { version: 1, method: 'snapshot', workspaceRoot: root });
	assert.equal(response.kind, 'snapshot');
	if (response.kind === 'snapshot') {
		assert.equal(response.snapshot.sessionId, session.sessionId);
	}
	await session.extensionRunner.emit({ type: 'session_start', reason: 'reload' });
	await requestBridge(socket, { version: 1, method: 'probe', workspaceRoot: root });
	await session.extensionRunner.emit({ type: 'session_shutdown', reason: 'quit' });
	assert.equal(fs.existsSync(socket), false);
});
