import * as test from 'node:test';
import * as assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import * as path from 'node:path';
import * as fs from 'node:fs';
import { startBridge } from './runtime/adjacent/transport';
import type { ChildProcessWithoutNullStreams } from 'node:child_process';
import type { AgentRuntimeProgress, BackendResponse } from './protocol';

const responseTimeoutMs = 2_000;
const stdoutBuffers = new WeakMap<NodeJS.ReadableStream, string>();

interface StdioProgressMessage {
	id: string;
	type: 'progress';
	progress: AgentRuntimeProgress;
}

type StdioMessage = BackendResponse | StdioProgressMessage;

const readJsonLineFromStdout = async (stream: NodeJS.ReadableStream, signal: AbortSignal): Promise<StdioMessage> => {
	const chunks: Buffer[] = [];

	while (true) {
		const buffered = stdoutBuffers.get(stream) ?? '';
		const bufferedNewline = buffered.indexOf('\n');
		if (bufferedNewline >= 0) {
			stdoutBuffers.set(stream, buffered.slice(bufferedNewline + 1));
			return JSON.parse(buffered.slice(0, bufferedNewline));
		}

		// SAFETY: this stdout stream is never put into object/string mode, so
		// Node's 'data' event always emits a Buffer chunk here.
		const [chunk] = await once(stream, 'data', { signal }) as [Buffer];
		chunks.push(chunk);
		const text = buffered + Buffer.concat(chunks).toString('utf8');
		const newline = text.indexOf('\n');
		if (newline >= 0) {
			stdoutBuffers.set(stream, text.slice(newline + 1));
			return JSON.parse(text.slice(0, newline));
		}
	}
};

const readJsonLine = async (
	child: ChildProcessWithoutNullStreams,
	stderrText: () => string
): Promise<StdioMessage> => {
	let timeout: NodeJS.Timeout | undefined;
	const listeners = new AbortController();

	const timeoutPromise = new Promise<never>((_resolve, reject) => {
		timeout = setTimeout(() => {
			reject(new Error(`timed out waiting for stdio server response. stderr: ${stderrText()}`));
		}, responseTimeoutMs);
	});
	const exitPromise = once(child, 'exit', { signal: listeners.signal }).then(([code, signal]) => {
		throw new Error(
			`stdio server exited before writing a response. code: ${String(code)}, signal: ${String(signal)}, stderr: ${stderrText()}`
		);
	});
	const errorPromise = once(child, 'error', { signal: listeners.signal }).then(([error]) => {
		throw new Error(
			`stdio server failed before writing a response: ${error instanceof Error ? error.message : String(error)}. stderr: ${stderrText()}`
		);
	});

	try {
		return await Promise.race([
			readJsonLineFromStdout(child.stdout, listeners.signal),
			timeoutPromise,
			exitPromise,
			errorPromise,
		]);
	} finally {
		clearTimeout(timeout);
		listeners.abort();
	}
};

const killAndWait = async (child: ChildProcessWithoutNullStreams): Promise<void> => {
	if (child.exitCode !== null || child.signalCode !== null) {
		return;
	}

	const closePromise = once(child, 'close');
	child.kill();
	await closePromise;
};

test('stdio server responds to explainSelection', async () => {
	const serverPath = path.resolve(__dirname, 'stdio-server.js');
	const child = spawn(process.execPath, [serverPath], {
		stdio: ['pipe', 'pipe', 'pipe'],
	});
	const stderrChunks: Buffer[] = [];
	child.stderr.on('data', (chunk: Buffer) => {
		stderrChunks.push(chunk);
	});
	const stderrText = (): string => Buffer.concat(stderrChunks).toString('utf8');

	try {
		child.stdin.write(`${JSON.stringify({
			id: 'req-stdio',
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
		})}\n`);

		let finalResponse = await readJsonLine(child, stderrText);
		let sawBackendProgress = false;
		while ('type' in finalResponse && finalResponse.type === 'progress') {
			assert.equal(finalResponse.id, 'req-stdio');
			sawBackendProgress = sawBackendProgress || finalResponse.progress.stage === 'backend_received';
			finalResponse = await readJsonLine(child, stderrText);
		}

		if ('type' in finalResponse) {
			throw new Error('expected a final backend response, not another progress message.');
		}

		assert.equal(sawBackendProgress, true);
		assert.equal(finalResponse.id, 'req-stdio');
		assert.equal(finalResponse.ok, true);
		assert.match(JSON.stringify(finalResponse), /Development agent runtime/);
	} finally {
		await killAndWait(child);
	}
});

test('the first backend command selects a runtime once, and backend restart rechecks', async (t) => {
	const root = fs.mkdtempSync('/tmp/vantage-stdio-selection-');
	t.after(() => fs.rmSync(root, { recursive: true, force: true }));
	const socket = path.join(root, 'pi.sock');
	const serverPath = path.resolve(__dirname, 'stdio-server.js');
	let child = spawn(process.execPath, [serverPath], { stdio: ['pipe', 'pipe', 'pipe'] });
	t.after(() => killAndWait(child));
	const status = async () => {
		child.stdin.write(JSON.stringify({
			id: 'status', method: 'agentSessionStatus',
			config: { agent: { runtime: 'adjacent-or-pi', adjacent: { socket_path: socket } } },
			params: { workspaceRoot: root, filePath: path.join(root, 'example.ts'), language: 'typescript', text: '', cursor: { line: 1, character: 1 } },
		}) + '\n');
		let message = await readJsonLine(child, () => '');
		while ('type' in message) {
			message = await readJsonLine(child, () => '');
		}
		assert.equal(message.ok, true);
		return JSON.stringify(message);
	};
	assert.doesNotMatch(await status(), /Runtime: adjacent Pi/);
	const close = await startBridge(socket, root, () => { throw new Error('No model request expected.'); });
	t.after(close);
	assert.doesNotMatch(await status(), /Runtime: adjacent Pi/, 'an agent appearing later must not switch the active runtime');
	await killAndWait(child);
	child = spawn(process.execPath, [serverPath], { stdio: ['pipe', 'pipe', 'pipe'] });
	assert.match(await status(), /Runtime: adjacent Pi/);
});
