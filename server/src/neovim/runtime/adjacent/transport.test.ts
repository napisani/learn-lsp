import * as test from 'node:test';
import * as assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import * as net from 'node:net';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { bridgeSocketPath, discoverBridge, requestBridge, startBridge } from './transport';
import type { Snapshot } from './protocol';

function fixture(t: test.TestContext) {
	const directory = fs.mkdtempSync('/tmp/vantage-bridge-test-');
	t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
	return { directory, root: directory, socket: bridgeSocketPath(directory, directory) };
}

function snapshot(root: string): Snapshot {
	return {
		sessionId: 'parent',
		leafId: null,
		workspaceRoot: fs.realpathSync(root),
		provider: 'openai',
		model: 'gpt-4o-mini',
		thinkingLevel: 'off',
		branch: '',
		entryCount: 0,
	};
}

test('discovers a private workspace socket, snapshots afresh, and cleans up', async (t) => {
	const { directory, root, socket } = fixture(t);
	let reads = 0;
	const close = await startBridge(socket, root, () => {
		reads++;
		return snapshot(root);
	});
	t.after(close);
	assert.equal(fs.statSync(socket).mode & 0o777, 0o600);
	assert.equal(await discoverBridge(root, undefined, directory), socket);
	assert.equal(reads, 0, 'discovery does not read the conversation');
	for (let i = 0; i < 2; i++) {
		const response = await requestBridge(socket, { version: 1, method: 'snapshot', workspaceRoot: root });
		assert.equal(response.kind, 'snapshot');
	}
	assert.equal(reads, 2);
	await close();
	await close();
	assert.equal(fs.existsSync(socket), false);
});

test('fails closed on ambiguity, missing agents, wrong workspace, and unavailable snapshots', async (t) => {
	const { directory, root, socket } = fixture(t);
	await assert.rejects(discoverBridge(root, undefined, directory), /No adjacent Pi/);
	const close = await startBridge(socket, root, () => {
		throw new Error('Adjacent Pi snapshot unavailable.');
	});
	t.after(close);
	const second = socket.replace('.sock', '-second.sock');
	const closeSecond = await startBridge(second, root, () => snapshot(root));
	t.after(closeSecond);
	await assert.rejects(discoverBridge(root, undefined, directory), /Multiple adjacent Pi/);
	await assert.rejects(requestBridge(socket, { version: 1, method: 'snapshot', workspaceRoot: root }), /snapshot unavailable/);
	await assert.rejects(
		requestBridge(socket, { version: 1, method: 'snapshot', workspaceRoot: '/tmp' }),
		/does not match/,
	);
});

test('rejects shared or symlinked endpoint directories', async (t) => {
	const { directory, root, socket } = fixture(t);
	fs.chmodSync(directory, 0o755);
	await assert.rejects(startBridge(socket, root, () => snapshot(root)), /owner-only/);
	fs.chmodSync(directory, 0o700);
	const link = path.join(directory, 'link');
	fs.symlinkSync(directory, link);
	await assert.rejects(startBridge(path.join(link, 'test.sock'), root, () => snapshot(root)), /owner-only/);
});

test('cancels an unanswered socket request and rejects a malformed response', async (t) => {
	const { socket, root } = fixture(t);
	const peers = new Set<net.Socket>();
	const server = net.createServer((peer) => {
		peers.add(peer);
		peer.on('error', () => {});
	});
	server.listen(socket);
	await once(server, 'listening');
	t.after(async () => {
		for (const peer of peers) {
			peer.destroy();
		}
		await new Promise<void>((resolve) => server.close(() => resolve()));
	});
	const controller = new AbortController();
	const pending = requestBridge(socket, { version: 1, method: 'snapshot', workspaceRoot: root }, controller.signal);
	const rejected = assert.rejects(pending, /cancelled/);
	controller.abort();
	await rejected;
	server.removeAllListeners('connection');
	server.on('connection', (peer) => {
		peers.add(peer);
		peer.on('error', () => {});
		peer.end('{bad json}\n');
	});
	await assert.rejects(
		requestBridge(socket, { version: 1, method: 'snapshot', workspaceRoot: root }),
		/Invalid adjacent Pi response/,
	);
});

test('communicates across processes and ignores crashed endpoints without a multiplexer', { timeout: 10000 }, async (t) => {
	const { socket, root, directory } = fixture(t);
	const child = spawn(process.execPath, [
		'-e',
		`
		const { startBridge } = require(${JSON.stringify(path.join(__dirname, 'transport.js'))});
		startBridge(${JSON.stringify(socket)}, ${JSON.stringify(root)}, () => (${JSON.stringify(snapshot(root))}))
			.then(() => process.stdout.write('ready\\n'));
	`,
	], { stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, TMUX: '', HERDR: '' } });
	t.after(async () => {
		if (child.exitCode === null && child.signalCode === null) {
			child.kill();
			await once(child, 'exit');
		}
	});
	await once(child.stdout, 'data');
	const response = await requestBridge(socket, { version: 1, method: 'snapshot', workspaceRoot: root });
	assert.equal(response.kind, 'snapshot');
	child.kill('SIGKILL');
	await once(child, 'exit');
	assert.equal(fs.existsSync(socket), true);
	await assert.rejects(discoverBridge(root, undefined, directory), /No adjacent Pi/);
	assert.equal(fs.existsSync(socket), true, 'discovery must not delete another process endpoint');
});
