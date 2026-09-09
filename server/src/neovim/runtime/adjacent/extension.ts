import * as fs from 'node:fs';
import type { ExtensionAPI, ExtensionContext } from '@earendil-works/pi-coding-agent';
import { bridgeSocketPath, startBridge } from './transport';
import type { Snapshot } from './protocol';

type SnapshotContext = Pick<ExtensionContext, 'isIdle' | 'hasPendingMessages' | 'model' | 'sessionManager' | 'cwd' | 'thinkingLevel'>;

/** Keep one immutable snapshot, refreshed only at complete conversation boundaries. */
export class SessionSnapshots {
	private completed?: Snapshot;

	capture(ctx: SnapshotContext): void {
		this.completed = snapshotSession(ctx);
	}

	read(ctx: SnapshotContext): Snapshot {
		if (ctx.isIdle() && !ctx.hasPendingMessages()) {
			this.capture(ctx);
		}
		if (!this.completed || this.completed.sessionId !== ctx.sessionManager.getSessionId()) {
			throw new Error('Adjacent Pi has no completed turn snapshot yet. Retry after its current turn completes.');
		}
		return { ...this.completed, parentBusy: !ctx.isIdle() || ctx.hasPendingMessages() };
	}
}

/** Called before a new prompt or after turn_end, when tool calls have their results. */
function snapshotSession(ctx: SnapshotContext): Snapshot {
	if (!ctx.model) {
		throw new Error('Adjacent Pi has no selected model.');
	}
	const entries = ctx.sessionManager.getBranch();
	return {
		sessionId: ctx.sessionManager.getSessionId(),
		leafId: ctx.sessionManager.getLeafId(),
		workspaceRoot: fs.realpathSync(ctx.cwd),
		provider: ctx.model.provider,
		model: ctx.model.id,
		thinkingLevel: ctx.thinkingLevel ?? 'off',
		branch: entries.map((entry) => JSON.stringify(entry)).join('\n'),
		entryCount: entries.length,
	};
}

export default function vantageAdjacent(pi: ExtensionAPI): void {
	let close: (() => Promise<void>) | undefined;
	let snapshots: SessionSnapshots | undefined;
	pi.on('session_start', async (_event, ctx) => {
		// Embedded forks must never advertise themselves as adjacent agents.
		if (ctx.mode !== 'tui') {
			return;
		}
		await close?.();
		const source = new SessionSnapshots();
		snapshots = source;
		if (ctx.model && ctx.isIdle() && !ctx.hasPendingMessages()) {
			source.capture(ctx);
		}
		const socketPath = bridgeSocketPath(ctx.cwd);
		close = await startBridge(socketPath, ctx.cwd, () => source.read(ctx));
		ctx.ui.setStatus('vantage-adjacent', 'Vantage bridge');
		ctx.ui.notify(`Vantage Pi bridge: ${socketPath}`, 'info');
	});
	pi.on('before_agent_start', (_event, ctx) => {
		// Captures tree navigation and idle changes before the new user turn is appended.
		snapshots?.capture(ctx);
	});
	pi.on('turn_end', (_event, ctx) => {
		// Pi has persisted the assistant message and every tool result by this event.
		snapshots?.capture(ctx);
	});
	pi.on('session_shutdown', async () => {
		await close?.();
		close = undefined;
		snapshots = undefined;
	});
}
