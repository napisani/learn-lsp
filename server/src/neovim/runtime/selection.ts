import * as path from 'node:path';
import type { BackendRequestConfig } from '../protocol';
import { discoverBridge, ensurePrivateDirectory, NoAdjacentBridgeError, requestBridge } from './adjacent/transport';

type SelectedRuntime = { runtime: 'pi' } | { runtime: 'adjacent'; socketPath: string };
type DetectBridge = (root: string, socketPath?: string, signal?: AbortSignal) => Promise<string | undefined>;

/** One sticky decision per backend process; concurrent first requests share the probe. */
export class AgentRuntimeSelection {
	private selected?: Promise<SelectedRuntime>;

	constructor(private readonly detect: DetectBridge = detectAdjacentBridge) {}

	async resolve(config: BackendRequestConfig, root: string, signal?: AbortSignal): Promise<BackendRequestConfig> {
		if (config.agent?.runtime !== 'adjacent-or-pi') {
			return config;
		}
		signal?.throwIfAborted();
		if (!this.selected) {
			const attempt = this.select(root, config.agent.adjacent?.socket_path, signal);
			this.selected = attempt;
			// Only successful choices stick; cancellation or a broken bridge must not
			// permanently poison selection or silently select a different conversation.
			void attempt.catch(() => {
				if (this.selected === attempt) {
					this.selected = undefined;
				}
			});
		}
		const selected = await this.selected;
		signal?.throwIfAborted();
		const agent = { ...config.agent, runtime: selected.runtime };
		if (selected.runtime === 'adjacent') {
			agent.adjacent = { ...agent.adjacent, socket_path: selected.socketPath };
		}
		return { ...config, agent };
	}

	private async select(root: string, socketPath?: string, signal?: AbortSignal): Promise<SelectedRuntime> {
		const detected = await this.detect(root, socketPath, signal);
		signal?.throwIfAborted();
		return detected === undefined ? { runtime: 'pi' } : { runtime: 'adjacent', socketPath: detected };
	}
}

async function detectAdjacentBridge(root: string, socketPath?: string, signal?: AbortSignal): Promise<string | undefined> {
	try {
		if (!socketPath) {
			return await discoverBridge(root, signal);
		}
		const socket = path.resolve(root, socketPath);
		ensurePrivateDirectory(path.dirname(socket));
		const response = await requestBridge(socket, { version: 1, method: 'probe', workspaceRoot: root }, signal);
		if (response.kind !== 'ready') {
			throw new Error('Invalid adjacent Pi probe response.');
		}
		return socket;
	} catch (error) {
		if (error instanceof NoAdjacentBridgeError) {
			return undefined;
		}
		if (socketPath && error instanceof Error && 'code' in error && ['ENOENT', 'ECONNREFUSED'].includes(String(error.code))) {
			return undefined;
		}
		throw error;
	}
}
