import * as fs from 'node:fs';
import * as os from 'node:os';
import type { AgentSession, ToolDefinition } from '@earendil-works/pi-coding-agent';
import type { AgentAuthConfig } from '../../protocol';
import { createModelTarget } from '../pi/model-target';
import type { AgentSessionHandle } from '../pi/session-store';
import { discoverBridge, ensurePrivateDirectory, requestBridge } from './transport';
import * as path from 'node:path';

export interface ForkedSession {
	session: AgentSessionHandle;
	source: { sessionId: string; leafId: string | null; provider: string; model: string; parentBusy?: boolean };
}

export async function forkAdjacentSession(
	root: string,
	customTools: ToolDefinition[],
	tools: string[],
	signal: AbortSignal,
	socketPath?: string,
	auth?: AgentAuthConfig,
): Promise<{ session: AgentSession; source: ForkedSession['source'] }> {
	const socket = socketPath ?? await discoverBridge(root, signal);
	ensurePrivateDirectory(path.dirname(socket));
	const response = await requestBridge(socket, { version: 1, method: 'snapshot', workspaceRoot: root }, signal);
	if (response.kind !== 'snapshot') {
		throw new Error('Adjacent Pi did not return a session snapshot.');
	}
	const snapshot = response.snapshot;
	if (snapshot.workspaceRoot !== fs.realpathSync(root)) {
		throw new Error('Adjacent Pi snapshot workspace mismatch.');
	}
	signal.throwIfAborted();
	const { piAgent, modelRuntime, model } = await createModelTarget({
		workspaceRoot: root,
		provider: snapshot.provider,
		model: snapshot.model,
		authPath: auth?.path,
	});
	signal.throwIfAborted();
	const entries = piAgent.parseSessionEntries(snapshot.branch);
	if (entries.length !== snapshot.entryCount || entries.some((entry) => entry.type === 'session')) {
		throw new Error('Invalid adjacent Pi branch.');
	}
	// Pi 0.85 no longer exposes a public in-memory constructor that accepts
	// preloaded entries. Seed an isolated temporary session file instead. The
	// generated header gives the fork a new identity, while the branch entries
	// retain their original ids and parent links so Pi can reconstruct context.
	const seed = piAgent.SessionManager.inMemory(root);
	const header = seed.getHeader();
	if (!header) {
		throw new Error('Could not create an adjacent Pi session header.');
	}
	const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'vantage-adjacent-'));
	const sessionPath = path.join(tempDir, 'session.jsonl');
	const cleanup = () => fs.rmSync(tempDir, { recursive: true, force: true });
	try {
		fs.writeFileSync(sessionPath, [header, ...entries].map((entry) => JSON.stringify(entry)).join('\n') + '\n', { mode: 0o600 });
		const sessionManager = piAgent.SessionManager.open(sessionPath, tempDir, root);
		if (sessionManager.getLeafId() !== snapshot.leafId) {
			throw new Error('Adjacent Pi branch leaf mismatch.');
		}

		// Do not reload the parent's extensions: they may inject prompts, expose more
		// tools, or start sockets. Vantage keeps its own command-specific tool policy.
		const resourceLoader = new piAgent.DefaultResourceLoader({
			cwd: root,
			agentDir: piAgent.getAgentDir(),
			noExtensions: true,
		});
		await resourceLoader.reload();
		signal.throwIfAborted();
		const { session } = await piAgent.createAgentSession({
			cwd: root,
			modelRuntime,
			model,
			thinkingLevel: snapshot.thinkingLevel,
			tools,
			customTools,
			sessionManager,
			resourceLoader,
		});
		if (signal.aborted) {
			session.dispose();
			signal.throwIfAborted();
		}

		// AgentSession disposes the manager but does not remove an explicitly opened
		// session file. Keep this compatibility file private and short-lived.
		const dispose = session.dispose.bind(session);
		session.dispose = () => {
			try {
				dispose();
			} finally {
				cleanup();
			}
		};
		return {
			session,
			source: {
				sessionId: snapshot.sessionId,
				leafId: snapshot.leafId,
				provider: snapshot.provider,
				model: snapshot.model,
				parentBusy: snapshot.parentBusy,
			},
		};
	} catch (error) {
		cleanup();
		throw error;
	}
}
