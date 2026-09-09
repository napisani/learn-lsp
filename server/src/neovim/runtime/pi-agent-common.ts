import * as fs from 'node:fs';
import * as path from 'node:path';
import type { AssistantMessage, TextContent, Type } from '@earendil-works/pi-ai';
import { importPiCodingAgent, type PiCodingAgentModule } from './pi/module';
import { requestCancellation } from './pi/request-cancellation';
import type { AgentSessionEvent, Skill, ToolDefinition } from '@earendil-works/pi-coding-agent';
import type { AgentRuntime, AgentRuntimeRequestContext } from './agent';
import type {
	AgentOptionsConfig,
	Annotation,
	AnnotateRangeParams,
	AnnotationResult,
	BaseRequestParams,
	EditAppliedResult,
	EditSelectionParams,
	ExplainSelectionParams,
	ExplanationResult,
	GenerateWalkthroughParams,
	QuestionSelectionParams,
	SearchLocation,
	SearchLocationsParams,
	SearchLocationsResult,
	AgentSessionOutputConfig,
	AgentSessionOutputParams,
	ListSkillsResult,
	SkillSummary,
	WalkthroughPointer,
	WalkthroughResult,
} from '../protocol';
import {
	buildAnnotationPrompt,
	buildAgentEditPrompt,
	buildExplainPrompt,
	buildQuestionPrompt,
	buildSearchPrompt,
	buildWalkthroughPrompt,
} from '../prompts';
import { errorMessage } from '../effect-errors';
import type { AgentSessionHandle, AgentSessionStore } from './pi/session-store';
import { createSubmitTools, parseSearchFallback, parseWalkthroughFallback, type SubmitToolSubmission } from '../submit-tools';

interface CommandConfig {
	include_lens?: boolean;
	options?: AgentOptionsConfig;
}

type CommandKind = 'explain' | 'question' | 'edit' | 'annotate' | 'search' | 'walkthrough';

/** Command configuration shared by both Pi-backed runtimes. */
export interface PiAgentOptions {
	options?: AgentOptionsConfig;
	commandOptions?: Partial<Record<CommandKind, CommandConfig>>;
	sessionOutput?: AgentSessionOutputConfig;
	store?: AgentSessionStore;
}

export interface PiSessionRequest {
	root: string;
	customTools: ToolDefinition[];
	activeTools: string[];
	transient: boolean;
	signal: AbortSignal;
	outputEntryId?: string;
}

/** The concrete runtime owns acquisition, request tracking, and session lifetime. */
export interface PiSessionLifecycle {
	acquire(request: PiSessionRequest): Promise<AgentSessionHandle>;
	trackRequest(transient: boolean): boolean;
	release(session: AgentSessionHandle | undefined, transient: boolean): void;
}

interface PiAgentCommonOptions extends PiAgentOptions {
	provider: string;
	model: string;
	store: AgentSessionStore;
	sessions: PiSessionLifecycle;
	statusNote?: string;
}


interface PiAiModule {
	Type: typeof Type;
}

type SubmissionContext = SubmitToolSubmission;


const READ_ONLY_TOOLS = ['read', 'grep', 'find', 'ls'];

/** Prompts, tools, streaming, results, and output history; no session-source policy. */
export class PiAgentCommon implements AgentRuntime {
	readonly provider: string;
	readonly model: string;
	readonly options: AgentOptionsConfig;
	readonly commandOptions: NonNullable<PiAgentOptions['commandOptions']>;
	private readonly store: AgentSessionStore;
	private readonly sessions: PiSessionLifecycle;
	private readonly statusNote?: string;
	private currentSubmission?: SubmissionContext;

	constructor(options: PiAgentCommonOptions) {
		this.provider = options.provider;
		this.model = options.model;
		this.options = options.options ?? {};
		this.commandOptions = options.commandOptions ?? {};
		this.store = options.store;
		this.sessions = options.sessions;
		this.statusNote = options.statusNote;
		this.store.setHistoryLimit?.(options.sessionOutput?.history_limit);
	}

	async explainSelection(params: ExplainSelectionParams, context: AgentRuntimeRequestContext = {}): Promise<ExplanationResult> {
		const prompt = buildExplainPrompt(this.paramsForLens(params, this.includeLens('explain', true)));
		const summary = `${params.filePath}:${params.cursor.line}`;
		return { kind: 'explanation', markdown: await this.runMarkdown('explain', params, prompt, context, READ_ONLY_TOOLS, summary) };
	}

	async questionSelection(params: QuestionSelectionParams, context: AgentRuntimeRequestContext = {}): Promise<ExplanationResult> {
		const prompt = buildQuestionPrompt(this.paramsForLens(params, this.includeLens('question', false)));
		const summary = params.question;
		return { kind: 'explanation', markdown: await this.runMarkdown('question', params, prompt, context, READ_ONLY_TOOLS, summary) };
	}

	/**
	 * Gives the Pi agent ownership of the complete edit. The agent can inspect
	 * the workspace and use Pi's native edit/write tools repeatedly; Vantage
	 * only acknowledges completion and never applies model-produced text.
	 */
	async editSelection(params: EditSelectionParams, context: AgentRuntimeRequestContext = {}): Promise<EditAppliedResult> {
		let assistantSummary = '';
		const prompt = buildAgentEditPrompt(this.paramsForLens(params, this.includeLens('edit', false)));
		await this.runPrompt(
			'edit',
			params,
			prompt,
			context,
			[...READ_ONLY_TOOLS, 'edit', 'write'],
			false,
			params.instruction,
			undefined,
			(text) => {
				assistantSummary = text;
			},
		);
		return {
			kind: 'edit_applied',
			summary: assistantSummary.trim() || 'Pi completed the requested edit.',
		};
	}

	async annotateRange(params: AnnotateRangeParams, context: AgentRuntimeRequestContext = {}): Promise<AnnotationResult> {
		let submitted: Annotation[] | undefined;
		const submission: SubmissionContext = {
			params,
			handlers: {
				onAnnotations: (annotations) => {
					submitted = annotations;
				},
			},
		};
		const prompt = buildAnnotationPrompt(params);
		await this.runPrompt('annotate', params, prompt, context, ['submit_annotations'], true, `${params.filePath} annotation request`, submission);
		if (!submitted) {
			throw new Error('Vantage annotate did not receive submit_annotations from the agent.');
		}
		return {
			kind: 'annotations',
			annotations: submitted,
		};
	}

	async searchLocations(params: SearchLocationsParams, context: AgentRuntimeRequestContext = {}): Promise<SearchLocationsResult> {
		let submitted: SearchLocation[] | undefined;
		let assistantFallback = '';
		const submission: SubmissionContext = {
			params,
			handlers: {
				onSearch: (locations) => {
					submitted = locations;
				},
			},
		};
		const prompt = buildSearchPrompt(this.paramsForLens(params, this.includeLens('search', true)));
		await this.runPrompt('search', params, prompt, context, [...READ_ONLY_TOOLS, 'submit_search_results'], false, params.query, submission, (text) => {
			assistantFallback = text;
		});
		if (!submitted && assistantFallback.trim().length > 0) {
			submitted = parseSearchFallback(workspaceRoot(params), assistantFallback);
		}
		if (!submitted) {
			throw new Error('Vantage search did not receive submit_search_results from the agent.');
		}
		return {
			kind: 'locations',
			locations: submitted,
		};
	}

	async generateWalkthrough(params: GenerateWalkthroughParams, context: AgentRuntimeRequestContext = {}): Promise<WalkthroughResult> {
		let submitted: WalkthroughPointer[] | undefined;
		let assistantFallback = '';
		const submission: SubmissionContext = {
			params,
			handlers: {
				onWalkthrough: (pointers) => {
					submitted = pointers;
				},
			},
		};
		const prompt = buildWalkthroughPrompt(this.paramsForLens(params, this.includeLens('walkthrough', true)));
		await this.runPrompt(
			'walkthrough',
			params,
			prompt,
			context,
			[...READ_ONLY_TOOLS, 'submit_walkthrough'],
			false,
			params.prompt,
			submission,
			(text) => {
				assistantFallback = text;
			}
		);
		if (!submitted && assistantFallback.trim().length > 0) {
			submitted = parseWalkthroughFallback(workspaceRoot(params), assistantFallback);
		}
		if (!submitted) {
			throw new Error('Vantage walkthrough did not receive submit_walkthrough from the agent.');
		}
		return writeWalkthroughFile(workspaceRoot(params), submitted);
	}

	async agentCancel(): Promise<ExplanationResult> {
		const cancelled = await this.store.cancel();
		return {
			kind: 'explanation',
			markdown: cancelled ? '## Vantage Agent\n\nCancelled active agent request.' : '## Vantage Agent\n\nNo active agent request.',
		};
	}

	async agentSessionReset(): Promise<ExplanationResult> {
		const removed = await this.store.reset();
		return {
			kind: 'explanation',
			markdown: removed ? '## Vantage Agent Session\n\nSession reset.' : '## Vantage Agent Session\n\nNo active session existed.',
		};
	}

	async agentSessionStatus(): Promise<ExplanationResult> {
		const status = this.store.status();
		return {
			kind: 'explanation',
			markdown: [
				'## Vantage Agent Session',
				'',
				this.statusNote,
				`Active request: ${status.active ? `\`${status.active}\`` : '`none`'}`,
				`Session: ${status.session ? '`active`' : '`none`'}`,
				status.session ? `Workspace: \`${status.session.workspaceRoot}\`` : undefined,
				status.session ? `Model target: \`${status.session.provider}/${status.session.model}\`` : undefined,
				status.session ? `Session age: ${formatAge(Date.now() - status.session.createdAt)}` : undefined,
				`Session turns: ${status.sessionTurnCount}`,
				status.lastCommandKind ? `Last command: \`${status.lastCommandKind}\`` : undefined,
				`Session output entries: ${status.outputHistoryCount} (up to ${status.historyLimit} kept)`,
			].filter((line): line is string => line !== undefined).join('\n'),
		};
	}

	async agentSessionOutput(params: AgentSessionOutputParams): Promise<ExplanationResult> {
		return {
			kind: 'explanation',
			markdown: this.store.renderOutput(params.raw),
		};
	}

	async listSkills(params: BaseRequestParams): Promise<ListSkillsResult> {
		const piAgent = await importPiCodingAgent();
		const cwd = workspaceRoot(params);
		const settingsManager = piAgent.SettingsManager.create(cwd, piAgent.getAgentDir());
		const resourceLoader = new piAgent.DefaultResourceLoader({
			cwd,
			agentDir: piAgent.getAgentDir(),
			settingsManager,
			noExtensions: true,
			noPromptTemplates: true,
			noThemes: true,
			noContextFiles: true,
		});
		await resourceLoader.reload();
		const result = resourceLoader.getSkills();
		return {
			kind: 'skills',
			skills: result.skills.map(skillSummary),
			diagnostics: result.diagnostics.map((diagnostic) => ({
				message: diagnostic.message,
				severity: diagnostic.type,
			})),
		};
	}

	private includeLens(command: CommandKind, defaultValue: boolean): boolean {
		return this.commandOptions[command]?.include_lens ?? defaultValue;
	}

	private commandOptionsFor(command: CommandKind): AgentOptionsConfig {
		const scoped = this.commandOptions[command]?.options;
		return { ...this.options, ...(scoped ?? {}) };
	}

	private paramsForLens<T extends BaseRequestParams>(params: T, includeLens: boolean): T {
		return includeLens ? params : { ...params, lens: undefined };
	}

	private async runMarkdown(
		kind: CommandKind,
		params: BaseRequestParams,
		prompt: string,
		context: AgentRuntimeRequestContext,
		tools: string[],
		summary: string
	): Promise<string> {
		let text = '';
		await this.runPrompt(kind, params, prompt, context, tools, false, summary, undefined, (value) => {
			text = value;
		});
		if (text.trim().length === 0) {
			throw new Error(`Vantage ${kind} produced an empty response.`);
		}
		return text.trim();
	}

	private async runPrompt(
		kind: CommandKind,
		params: BaseRequestParams,
		prompt: string,
		context: AgentRuntimeRequestContext,
		activeTools: string[],
		transient: boolean,
		summary: string,
		submission?: SubmissionContext,
		onAssistantText?: (text: string) => void
	): Promise<void> {
		const outputEntryId = this.store.startOutputEntry?.({
			kind,
			transient,
			provider: this.provider,
			model: this.model,
			userSummary: summary,
			prompt,
		});
		context.reportProgress?.({ stage: 'agent_session_start', message: `Starting Vantage ${kind} agent request.` });
		this.store.appendOutputEvent?.(outputEntryId, { type: 'request_start', summary: `Started ${kind} request.` });
		let session: AgentSessionHandle | undefined;
		const cancellation = requestCancellation(context.signal, this.commandOptionsFor(kind).timeoutMs, async () => {
			await session?.abort();
		});
		const tracked = this.sessions.trackRequest(transient);
		if (tracked) {
			try {
				this.store.begin(kind, cancellation.abort, outputEntryId);
			} catch (error) {
				cancellation.dispose();
				this.store.finishOutputEntry?.(outputEntryId, 'failed', errorMessage(error));
				throw error;
			}
		}
		const previousSubmission = this.currentSubmission;
		let unsubscribe: (() => void) | undefined;
		try {
			cancellation.signal.throwIfAborted();
			session = await this.acquireSession(params, activeTools, transient, cancellation.signal, outputEntryId);
			cancellation.signal.throwIfAborted();
			session.setActiveToolsByName(activeTools);
			this.currentSubmission = submission ? { ...submission, outputEntryId } : undefined;
			unsubscribe = session.subscribe((event) => {
				this.store.appendOutputEvent?.(outputEntryId, {
					type: event.type,
					summary: eventSummary(event),
					details: event,
				});
				if (event.type === 'message_update') {
					context.reportProgress?.({ stage: 'agent_message_update', message: `Vantage ${kind} agent is responding.` });
				}
				if (event.type === 'tool_execution_start') {
					context.reportProgress?.({
						stage: 'agent_tool_started',
						message: `Vantage ${kind} agent called ${event.toolName}.`,
						details: { toolName: event.toolName },
					});
				}
				if (event.type === 'message_end' && event.message.role === 'assistant') {
					const text = assistantText(event.message);
					this.store.setAssistantText?.(outputEntryId, text);
					onAssistantText?.(text);
				}
			});
			await session.prompt(prompt, { source: 'rpc' });
			cancellation.signal.throwIfAborted();
			this.store.finishOutputEntry?.(outputEntryId, 'completed');
			context.reportProgress?.({ stage: 'agent_request_completed', message: `Vantage ${kind} agent request completed.` });
		} catch (error) {
			const status = cancellation.signal.aborted ? 'cancelled' : 'failed';
			this.store.finishOutputEntry?.(outputEntryId, status, status === 'failed' ? errorMessage(error) : undefined);
			throw error;
		} finally {
			this.currentSubmission = previousSubmission;
			cancellation.dispose();
			unsubscribe?.();
			this.sessions.release(session, transient);
			if (tracked) {
				this.store.end();
			}
		}
	}

	private async acquireSession(
		params: BaseRequestParams, activeTools: string[], transient: boolean,
		signal: AbortSignal, outputEntryId?: string,
	): Promise<AgentSessionHandle> {
		const customTools = await this.submissionTools();
		const root = workspaceRoot(params);
		signal.throwIfAborted();
		return this.sessions.acquire({ root, customTools, activeTools, transient, signal, outputEntryId });
	}

	/**
	 * Builds the submit_* tool set. Not part of the public `AgentRuntime`
	 * contract; exposed (non-private) so tests can grab the real registered
	 * tool objects instead of re-implementing their dispatch logic.
	 */
	async submissionTools(): Promise<ToolDefinition[]> {
		const piAgent = await importPiCodingAgent();
		const piAi = await importPiAi();
		return createSubmitTools({
			Type: piAi.Type,
			defineTool: piAgent.defineTool,
			requireSubmission: (toolName) => this.requireSubmission(toolName),
			workspaceRoot,
			output: this.store,
		});
	}

	private requireSubmission(toolName: string): SubmissionContext {
		if (!this.currentSubmission) {
			throw new Error(`${toolName} was called outside an active Vantage submit request.`);
		}
		return this.currentSubmission;
	}
}

function formatAge(ms: number): string {
	const totalSeconds = Math.max(0, Math.floor(ms / 1000));
	if (totalSeconds < 60) {
		return `${totalSeconds}s`;
	}
	const minutes = Math.floor(totalSeconds / 60);
	const seconds = totalSeconds % 60;
	if (minutes < 60) {
		return `${minutes}m${seconds}s`;
	}
	const hours = Math.floor(minutes / 60);
	const remainingMinutes = minutes % 60;
	return `${hours}h${remainingMinutes}m`;
}

function eventSummary(event: AgentSessionEvent): string {
	if ('toolName' in event && event.type.includes('tool')) {
		return `${event.type}: ${event.toolName}`;
	}
	if (event.type === 'message_update') {
		return 'assistant response updated';
	}
	if (event.type === 'message_end') {
		return 'message completed';
	}
	return event.type;
}

function skillSummary(skill: Skill): SkillSummary {
	return {
		name: skill.name,
		description: skill.description,
		filePath: skill.filePath,
		source: skill.sourceInfo.source,
	};
}


function workspaceRoot(params: BaseRequestParams): string {
	return params.workspaceRoot && params.workspaceRoot.trim().length > 0 ? params.workspaceRoot : path.dirname(params.filePath);
}

function writeWalkthroughFile(root: string, pointers: WalkthroughPointer[]): WalkthroughResult {
	const walkthroughDir = path.join(root, '.vantage');
	const walkthroughPath = path.join(walkthroughDir, 'walkthrough.json');
	fs.mkdirSync(walkthroughDir, { recursive: true });
	fs.writeFileSync(walkthroughPath, JSON.stringify({ version: 1, pointers }, null, 2));
	return {
		kind: 'walkthrough',
		path: walkthroughPath,
		pointerCount: pointers.length,
	};
}

function assistantText(message: AssistantMessage): string {
	return message.content
		.filter((block): block is TextContent => block.type === 'text')
		.map((block) => block.text)
		.join('\n');
}



export async function loadCodingAgentModuleForTest(): Promise<PiCodingAgentModule> {
	return importPiCodingAgent();
}

async function importPiAi(): Promise<PiAiModule> {
	// SAFETY: `new Function` only knows about the generic `Function` type; the
	// specifier below is the literal peer-dependency path this module requires
	// at runtime, so the resolved module shape matches `PiAiModule`.
	const dynamicImport = new Function('specifier', 'return import(specifier)') as (
		specifier: string
	) => Promise<PiAiModule>;
	return dynamicImport('@earendil-works/pi-ai');
}

export function codingAgentErrorMessage(cause: unknown): string {
	return errorMessage(cause);
}
