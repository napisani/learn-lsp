import * as fs from 'node:fs';
import * as net from 'node:net';
import * as path from 'node:path';
import { createHash } from 'node:crypto';
import {
	type BridgeRequest,
	type BridgeResponse,
	IPC_TIMEOUT_MS,
	MAX_RESPONSE_BYTES,
	RequestSchema,
	ResponseSchema,
	type Snapshot,
} from './protocol';

export function bridgeDirectory(): string {
	// Keep below Unix's socket-path limit, including on macOS (whose tmpdir is long).
	return `/tmp/vantage-pi-${process.getuid!()}`;
}

export function ensurePrivateDirectory(directory: string): void {
	fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
	const stat = fs.lstatSync(directory);
	if (!stat.isDirectory() || stat.uid !== process.getuid!() || (stat.mode & 0o077) !== 0) {
		throw new Error(`Vantage Pi bridge directory must be owner-only: ${directory}`);
	}
}

function workspacePrefix(root: string): string {
	return createHash('sha256').update(fs.realpathSync(root)).digest('hex').slice(0, 16) + '-';
}

export function bridgeSocketPath(root: string, directory = bridgeDirectory()): string {
	return path.join(directory, `${workspacePrefix(root)}${process.pid}.sock`);
}

/** One bounded request per connection; no terminal or multiplexer involvement. */
export async function startBridge(
	socketPath: string,
	workspaceRoot: string,
	snapshot: () => Snapshot,
): Promise<() => Promise<void>> {
	ensurePrivateDirectory(path.dirname(socketPath));
	const root = fs.realpathSync(workspaceRoot);
	const sockets = new Set<net.Socket>();
	const server = net.createServer((socket) => {
		sockets.add(socket);
		const timer = setTimeout(() => socket.destroy(), IPC_TIMEOUT_MS);
		socket.on('error', () => socket.destroy());
		socket.on('close', () => {
			clearTimeout(timer);
			sockets.delete(socket);
		});
		let input = '';
		let answered = false;
		socket.setEncoding('utf8');
		socket.on('data', (chunk: string) => {
			if (answered) {
				return;
			}
			input += chunk;
			if (Buffer.byteLength(input) > 16384) {
				socket.destroy();
				return;
			}
			if (!input.includes('\n')) {
				return;
			}
			answered = true;
			let response: BridgeResponse;
			try {
				const request = RequestSchema.parse(JSON.parse(input.slice(0, input.indexOf('\n'))));
				if (fs.realpathSync(request.workspaceRoot) !== root) {
					throw new Error('Adjacent Pi workspace does not match Vantage.');
				}
				response = request.method === 'probe'
					? { version: 1, kind: 'ready' }
					: { version: 1, kind: 'snapshot', snapshot: snapshot() };
			} catch (error) {
				response = { version: 1, kind: 'error', message: error instanceof Error ? error.message : String(error) };
			}
			let output = JSON.stringify(response) + '\n';
			if (Buffer.byteLength(output) > MAX_RESPONSE_BYTES) {
				output = JSON.stringify({ version: 1, kind: 'error', message: 'Adjacent Pi snapshot exceeds 32 MiB.' }) + '\n';
			}
			socket.end(output);
		});
	});
	await new Promise<void>((resolve, reject) => {
		server.once('error', reject);
		server.listen(socketPath, () => {
			server.removeListener('error', reject);
			resolve();
		});
	});
	// The containing directory was private before listen; chmod is not the access gate.
	fs.chmodSync(socketPath, 0o600);
	let closed = false;
	return async () => {
		if (closed) {
			return;
		}
		closed = true;
		for (const socket of sockets) {
			socket.destroy();
		}
		await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
	};
}

export function requestBridge(
	socketPath: string,
	request: BridgeRequest,
	signal?: AbortSignal,
): Promise<BridgeResponse> {
	return new Promise((resolve, reject) => {
		if (signal?.aborted) {
			reject(signal.reason);
			return;
		}
		const socket = net.createConnection(socketPath);
		let input = '';
		let settled = false;
		const finish = (error?: Error, response?: BridgeResponse) => {
			if (settled) {
				return;
			}
			settled = true;
			clearTimeout(timer);
			signal?.removeEventListener('abort', abort);
			socket.destroy();
			if (error) {
				reject(error);
			} else {
				resolve(response!);
			}
		};
		const abort = () => finish(new Error('Adjacent Pi request cancelled.'));
		const timer = setTimeout(() => finish(new Error('Adjacent Pi IPC timed out.')), IPC_TIMEOUT_MS);
		signal?.addEventListener('abort', abort, { once: true });
		socket.on('error', (error) => finish(error));
		socket.on('end', () => finish(new Error('Adjacent Pi disconnected before replying.')));
		socket.on('connect', () => socket.write(JSON.stringify(request) + '\n'));
		socket.setEncoding('utf8');
		socket.on('data', (chunk: string) => {
			input += chunk;
			if (Buffer.byteLength(input) > MAX_RESPONSE_BYTES) {
				finish(new Error('Adjacent Pi response exceeds 32 MiB.'));
				return;
			}
			const newline = input.indexOf('\n');
			if (newline < 0) {
				return;
			}
			try {
				const response = ResponseSchema.parse(JSON.parse(input.slice(0, newline)));
				if (response.kind === 'error') {
					finish(new Error(response.message));
				} else {
					finish(undefined, response);
				}
			} catch (error) {
				finish(new Error('Invalid adjacent Pi response.', { cause: error }));
			}
		});
	});
}

export class NoAdjacentBridgeError extends Error {
	constructor() {
		super('No adjacent Pi bridge found for this workspace. Load the Vantage Pi extension in Pi.');
		this.name = 'NoAdjacentBridgeError';
	}
}

export async function discoverBridge(
	root: string,
	signal?: AbortSignal,
	directory = bridgeDirectory(),
): Promise<string> {
	ensurePrivateDirectory(directory);
	const prefix = workspacePrefix(root);
	const candidates = fs.readdirSync(directory).filter((name) => name.startsWith(prefix) && name.endsWith('.sock'));
	const probed = await Promise.all(candidates.map(async (name) => {
		const socketPath = path.join(directory, name);
		try {
			const response = await requestBridge(socketPath, { version: 1, method: 'probe', workspaceRoot: root }, signal);
			if (response.kind !== 'ready') {
				throw new Error('Invalid adjacent Pi probe response.');
			}
			return socketPath;
		} catch (error) {
			// Crashes may leave socket files. Never remove another process's endpoint.
			if (!(error instanceof Error) || !('code' in error) || !['ENOENT', 'ECONNREFUSED'].includes(String(error.code))) {
				throw error;
			}
			return undefined;
		}
	}));
	const live = probed.filter((socketPath) => socketPath !== undefined);
	if (live.length === 0) {
		throw new NoAdjacentBridgeError();
	}
	if (live.length !== 1) {
		throw new Error(`Multiple adjacent Pi agents found. Set agent.adjacent.socket_path to one of: ${live.join(', ')}`);
	}
	return live[0];
}
