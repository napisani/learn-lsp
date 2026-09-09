import type { AgentSessionEventListener, PromptOptions } from '@earendil-works/pi-coding-agent';

/**
 * The subset of `AgentSession` that `CodingAgentRuntime` actually drives.
 * Depending on this instead of the concrete SDK class lets tests supply a
 * minimal session double without an unsafe cast — a real `AgentSession`
 * satisfies this interface structurally, so production code is unaffected.
 */
export interface AgentSessionHandle {
	setActiveToolsByName(toolNames: string[]): void;
	subscribe(listener: AgentSessionEventListener): () => void;
	prompt(text: string, options?: PromptOptions): Promise<void>;
	abort(): Promise<void>;
	dispose(): void;
}

interface SessionRecord {
	workspaceRoot: string;
	provider: string;
	model: string;
	session: AgentSessionHandle;
	createdAt: number;
}

interface ActiveRequest {
	kind: string;
	abort: () => Promise<void> | void;
	outputEntryId?: string;
}

export type SessionOutputStatus = 'running' | 'completed' | 'failed' | 'cancelled';

export interface SessionOutputEvent {
	time: number;
	type: string;
	summary: string;
	details?: unknown;
}

export interface StartOutputEntryInput {
	kind: string;
	transient: boolean;
	provider: string;
	model: string;
	userSummary: string;
	prompt: string;
}

export interface GetOrCreateSessionOptions {
	workspaceRoot: string;
	provider: string;
	model: string;
	createSession: () => Promise<AgentSessionHandle>;
}

/**
 * The subset of `CodingAgentSessionStore` that `CodingAgentRuntime` depends
 * on. Kept separate from the concrete class so tests can supply a minimal
 * fake without an unsafe cast, and so members `CodingAgentRuntime` only
 * calls defensively (via `?.`) are genuinely optional in the contract.
 */
export interface AgentSessionStore {
	setHistoryLimit?(limit: number | undefined): void;
	begin(kind: string, abort: () => Promise<void> | void, outputEntryId?: string): void;
	end(): void;
	cancel(): Promise<boolean>;
	reset(): Promise<boolean>;
	status(): SessionStoreStatus;
	startOutputEntry?(input: StartOutputEntryInput): string;
	appendOutputEvent?(entryId: string | undefined, event: Omit<SessionOutputEvent, 'time'>): void;
	setAssistantText?(entryId: string | undefined, assistantText: string): void;
	finishOutputEntry?(entryId: string | undefined, status: SessionOutputStatus, error?: string): void;
	renderOutput(raw: boolean | undefined): string;
	getOrCreate(options: GetOrCreateSessionOptions): Promise<AgentSessionHandle>;
}

interface SessionOutputEntry {
	id: string;
	kind: string;
	transient: boolean;
	status: SessionOutputStatus;
	startedAt: number;
	endedAt?: number;
	provider: string;
	model: string;
	userSummary: string;
	prompt: string;
	assistantText?: string;
	events: SessionOutputEvent[];
	error?: string;
}

export interface SessionStoreStatus {
	active?: string;
	session?: SessionRecord;
	outputHistoryCount: number;
	historyLimit: number;
	/** Count of non-transient output entries — annotation runs are transient and don't share buddy-session memory. */
	sessionTurnCount: number;
	lastCommandKind?: string;
	lastCommandAt?: number;
}

export class CodingAgentSessionStore implements AgentSessionStore {
	private record?: SessionRecord;
	private active?: ActiveRequest;
	private outputHistory: SessionOutputEntry[] = [];
	private outputSequence = 0;
	private historyLimit = 10;

	setHistoryLimit(limit: number | undefined): void {
		if (Number.isInteger(limit) && Number(limit) > 0) {
			this.historyLimit = Number(limit);
		}
		this.trimHistory();
	}

	isActive(): boolean {
		return this.active !== undefined;
	}

	activeKind(): string | undefined {
		return this.active?.kind;
	}

	begin(kind: string, abort: () => Promise<void> | void, outputEntryId?: string): void {
		if (this.active) {
			throw new Error(`Vantage agent is already running ${this.active.kind}. Use :VantageAgentCancel first.`);
		}
		this.active = { kind, abort, outputEntryId };
	}

	end(): void {
		this.active = undefined;
	}

	async cancel(): Promise<boolean> {
		const active = this.active;
		if (!active) {
			return false;
		}
		this.finishOutputEntry(active.outputEntryId, 'cancelled');
		await active.abort();
		// The request owns end(): cancellation can arrive while session setup is
		// still awaiting I/O. Keep the slot reserved until its finally runs.
		return true;
	}

	async reset(): Promise<boolean> {
		if (this.active) {
			throw new Error('Vantage agent is busy. Use :VantageAgentCancel before reset.');
		}
		const hadState = this.record !== undefined || this.outputHistory.length > 0;
		if (this.record) {
			this.record.session.dispose();
			this.record = undefined;
		}
		this.outputHistory = [];
		return hadState;
	}

	status(): SessionStoreStatus {
		const sessionEntries = this.outputHistory.filter((entry) => !entry.transient);
		const lastCommand = sessionEntries[sessionEntries.length - 1];
		return {
			active: this.active?.kind,
			session: this.record,
			outputHistoryCount: this.outputHistory.length,
			historyLimit: this.historyLimit,
			sessionTurnCount: sessionEntries.length,
			lastCommandKind: lastCommand?.kind,
			lastCommandAt: lastCommand?.startedAt,
		};
	}

	startOutputEntry(input: StartOutputEntryInput): string {
		const id = `session-output-${++this.outputSequence}`;
		this.outputHistory.push({
			id,
			kind: input.kind,
			transient: input.transient,
			status: 'running',
			startedAt: Date.now(),
			provider: input.provider,
			model: input.model,
			userSummary: input.userSummary,
			prompt: input.prompt,
			events: [],
		});
		this.trimHistory();
		return id;
	}

	appendOutputEvent(entryId: string | undefined, event: Omit<SessionOutputEvent, 'time'>): void {
		const entry = this.findOutputEntry(entryId);
		if (!entry) {
			return;
		}
		entry.events.push({ time: Date.now(), ...event });
	}

	setAssistantText(entryId: string | undefined, assistantText: string): void {
		const entry = this.findOutputEntry(entryId);
		if (entry) {
			entry.assistantText = assistantText;
		}
	}

	finishOutputEntry(entryId: string | undefined, status: SessionOutputStatus, error?: string): void {
		const entry = this.findOutputEntry(entryId);
		if (!entry || entry.status === 'cancelled') {
			return;
		}
		entry.status = status;
		entry.endedAt = Date.now();
		if (error) {
			entry.error = error;
		}
	}

	renderOutput(raw: boolean | undefined): string {
		return renderSessionOutput(this.outputHistory, raw === true);
	}

	private findOutputEntry(entryId: string | undefined): SessionOutputEntry | undefined {
		return entryId ? this.outputHistory.find((entry) => entry.id === entryId) : undefined;
	}

	private trimHistory(): void {
		while (this.outputHistory.length > this.historyLimit) {
			this.outputHistory.shift();
		}
	}

	async getOrCreate(options: GetOrCreateSessionOptions): Promise<AgentSessionHandle> {
		if (this.record && this.record.workspaceRoot === options.workspaceRoot) {
			return this.record.session;
		}

		if (this.record) {
			this.record.session.dispose();
			this.record = undefined;
		}

		const session = await options.createSession();
		this.record = {
			workspaceRoot: options.workspaceRoot,
			provider: options.provider,
			model: options.model,
			session,
			createdAt: Date.now(),
		};
		return session;
	}
}

function renderSessionOutput(entries: SessionOutputEntry[], raw: boolean): string {
	const lines = ['## Vantage Session Output', ''];
	if (entries.length === 0) {
		lines.push('No Vantage session activity recorded yet.');
		return lines.join('\n');
	}

	for (const entry of entries) {
		const transient = entry.transient ? ' · transient' : '';
		lines.push(`### ${entry.kind}${transient} · ${entry.status} · ${entry.provider}/${entry.model} · ${formatTime(entry.startedAt)}`);
		lines.push('');
		lines.push(`- Started: ${new Date(entry.startedAt).toISOString()}`);
		if (entry.endedAt) {
			lines.push(`- Ended: ${new Date(entry.endedAt).toISOString()}`);
		}
		lines.push(`- Request: ${entry.userSummary}`);
		if (entry.error) {
			lines.push(`- Error: ${entry.error}`);
		}
		const events = raw ? entry.events : curatedEvents(entry.events);
		if (events.length > 0) {
			lines.push('', '#### Tool and agent activity');
			for (const event of events) {
				lines.push(`- ${formatTime(event.time)} ${event.summary}`);
			}
		}
		if (entry.assistantText?.trim()) {
			lines.push('', '#### Assistant', '', entry.assistantText.trim());
		}
		if (raw) {
			lines.push('', '#### Raw prompt', '', '```text', entry.prompt, '```');
			lines.push('', '#### Raw events', '', '```json');
			lines.push(JSON.stringify(entry.events, null, 2));
			lines.push('```');
		}
		lines.push('');
	}
	return lines.join('\n').trimEnd();
}

function curatedEvents(events: SessionOutputEvent[]): SessionOutputEvent[] {
	let messageUpdates = 0;
	let lastMessageUpdateTime = Date.now();
	const curated: SessionOutputEvent[] = [];
	for (const event of events) {
		if (event.type === 'message_update') {
			messageUpdates += 1;
			lastMessageUpdateTime = event.time;
			continue;
		}
		if (event.summary === 'message completed' || event.type === 'message_start') {
			continue;
		}
		curated.push(event);
	}
	if (messageUpdates > 0) {
		curated.push({
			time: lastMessageUpdateTime,
			type: 'message_updates',
			summary: `assistant streamed ${messageUpdates} update(s)`,
		});
	}
	return curated.sort((left, right) => left.time - right.time);
}

function formatTime(value: number): string {
	return new Date(value).toISOString().slice(11, 19);
}
