import * as test from 'node:test';
import * as assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { AgentRuntimeSelection } from './selection';
import { bridgeSocketPath, startBridge } from './adjacent/transport';
import { BackendRequestConfigSchema } from '../protocol';
import { createAgentRuntimeFromConfig } from './agent-factory';
import { AdjacentAgentRuntime } from './adjacent/agent';
import { PiAgenticRuntime } from './pi/agent';

const hybrid = BackendRequestConfigSchema.parse({ agent: { runtime: 'adjacent-or-pi' } });

test('missing adjacent agent selects Pi once, retaining later model configuration', async () => {
	let calls = 0;
	const selection = new AgentRuntimeSelection(async () => { calls++; return undefined; });
	const first = await selection.resolve(hybrid, '/repo');
	assert.equal(first.agent?.runtime, 'pi');
	assert.ok(createAgentRuntimeFromConfig(first) instanceof PiAgenticRuntime);
	const next = await selection.resolve({ agent: { ...hybrid.agent, model: 'changed-model', options: { timeoutMs: 123 } } }, '/different-root');
	assert.equal(next.agent?.runtime, 'pi');
	assert.equal(next.agent?.model, 'changed-model');
	assert.equal(next.agent?.options?.timeoutMs, 123);
	assert.equal(calls, 1);
});

test('an adjacent match pins its endpoint and concurrent first commands share detection', async () => {
	let calls = 0;
	let release!: (socket: string) => void;
	const pending = new Promise<string>((resolve) => { release = resolve; });
	const selection = new AgentRuntimeSelection(async () => { calls++; return pending; });
	const first = selection.resolve(hybrid, '/repo');
	const second = selection.resolve(hybrid, '/repo');
	assert.equal(calls, 1);
	release('/tmp/private/selected.sock');
	const configs = await Promise.all([first, second]);
	assert.deepEqual(configs[0], configs[1]);
	assert.ok(createAgentRuntimeFromConfig(configs[0]) instanceof AdjacentAgentRuntime);
	const next = await selection.resolve({ agent: { ...hybrid.agent, adjacent: { socket_path: '/tmp/other.sock' } } }, '/other-root');
	assert.equal(next.agent?.adjacent?.socket_path, '/tmp/private/selected.sock');
	assert.equal(calls, 1);
});

test('explicit runtimes bypass selection and unresolved hybrid configs cannot silently become Pi', async () => {
	let calls = 0;
	const selection = new AgentRuntimeSelection(async () => { calls++; return undefined; });
	const pi = BackendRequestConfigSchema.parse({ agent: { runtime: 'pi' } });
	const adjacent = BackendRequestConfigSchema.parse({ agent: { runtime: 'adjacent' } });
	assert.equal(await selection.resolve(pi, '/repo'), pi);
	assert.equal(await selection.resolve(adjacent, '/repo'), adjacent);
	assert.equal(calls, 0);
	assert.throws(() => createAgentRuntimeFromConfig(hybrid), /Resolve adjacent-or-pi/);
});

test('detection failures and cancellation do not become sticky Pi fallbacks', async () => {
	let calls = 0;
	const selection = new AgentRuntimeSelection(async () => {
		calls++;
		if (calls === 1) { throw new Error('Multiple adjacent Pi agents found.'); }
		return '/tmp/private/pi.sock';
	});
	await assert.rejects(selection.resolve(hybrid, '/repo'), /Multiple adjacent/);
	assert.equal((await selection.resolve(hybrid, '/repo')).agent?.runtime, 'adjacent');
	const controller = new AbortController();
	controller.abort(new Error('cancelled'));
	await assert.rejects(selection.resolve(hybrid, '/repo', controller.signal), /cancelled/);
	assert.equal(calls, 2);
});

test('cancelling an in-flight initial probe leaves the next command free to select', async () => {
	let calls = 0;
	const selection = new AgentRuntimeSelection(async () => { calls++; return undefined; });
	const controller = new AbortController();
	const pending = selection.resolve(hybrid, '/repo', controller.signal);
	controller.abort(new Error('cancelled during detection'));
	await assert.rejects(pending, /cancelled during detection/);
	assert.equal((await selection.resolve(hybrid, '/repo')).agent?.runtime, 'pi');
	assert.equal(calls, 2);
});

test('real discovery falls back only for absence, not ambiguity or unsafe directories', async (t) => {
	const root = fs.mkdtempSync('/tmp/vantage-selection-');
	t.after(() => fs.rmSync(root, { recursive: true, force: true }));
	const missing = new AgentRuntimeSelection();
	assert.equal((await missing.resolve(hybrid, root)).agent?.runtime, 'pi');
	const socket = bridgeSocketPath(root);
	const close = await startBridge(socket, root, () => { throw new Error('Snapshot not ready.'); });
	t.after(close);
	assert.equal((await missing.resolve(hybrid, root)).agent?.runtime, 'pi', 'late agents do not change the initial choice');
	const found = await new AgentRuntimeSelection().resolve(hybrid, root);
	assert.equal(found.agent?.runtime, 'adjacent', 'detection probes availability, not turn readiness');
	assert.equal(found.agent?.adjacent?.socket_path, socket);
	const second = socket.replace('.sock', '-second.sock');
	const closeSecond = await startBridge(second, root, () => { throw new Error('Snapshot not ready.'); });
	t.after(closeSecond);
	await assert.rejects(new AgentRuntimeSelection().resolve(hybrid, root), /Multiple adjacent/);
	const unsafe = path.join(root, 'unsafe');
	fs.mkdirSync(unsafe, { mode: 0o755 });
	fs.chmodSync(unsafe, 0o755);
	await assert.rejects(new AgentRuntimeSelection().resolve({ agent: { ...hybrid.agent, adjacent: { socket_path: path.join(unsafe, 'pi.sock') } } }, root), /owner-only/);
	await assert.rejects(new AgentRuntimeSelection().resolve(hybrid, path.join(root, 'missing-workspace')), /ENOENT/);
});

test('explicit unavailable sockets fall back once without invoking a model', async (t) => {
	const root = fs.mkdtempSync('/tmp/vantage-explicit-selection-');
	t.after(() => fs.rmSync(root, { recursive: true, force: true }));
	const config = { agent: { ...hybrid.agent, adjacent: { socket_path: path.join(root, 'missing.sock') } } };
	assert.equal((await new AgentRuntimeSelection().resolve(config, root)).agent?.runtime, 'pi');
});
