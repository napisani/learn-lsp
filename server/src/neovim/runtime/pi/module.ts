import type {
	AgentSession,
	DefaultResourceLoader,
	ResourceLoader,
	parseSessionEntries,
	ModelRuntime,
	SessionManager,
	SettingsManager,
	ToolDefinition,
} from '@earendil-works/pi-coding-agent';
import type { Model } from '@earendil-works/pi-ai';

/**
 * The shape of `@earendil-works/pi-coding-agent` that Vantage relies on.
 *
 * One declaration for both runtimes. They are otherwise independent -- the
 * agentic runtime and the completion runtime share no behavior -- but they do
 * load the same peer dependency, and having two copies of this type meant two
 * places to update whenever Pi's surface moved.
 */
export interface PiCodingAgentModule {
	ModelRuntime: typeof ModelRuntime;
	SessionManager: typeof SessionManager;
	parseSessionEntries: typeof parseSessionEntries;
	SettingsManager: typeof SettingsManager;
	DefaultResourceLoader: typeof DefaultResourceLoader;
	getAgentDir(): string;
	createAgentSession(options?: {
		cwd?: string;
		resourceLoader?: ResourceLoader;
		modelRuntime?: ModelRuntime;
		model?: Model<never>;
		thinkingLevel?: string;
		tools?: string[];
		customTools?: ToolDefinition[];
		sessionManager?: SessionManager;
	}): Promise<{ session: AgentSession }>;
	defineTool<T extends ToolDefinition>(tool: T): T;
}

/**
 * Loads the Pi coding-agent module at runtime.
 *
 * Dynamic rather than a static import because Pi is an ESM-only peer
 * dependency: a static import would force this CommonJS build to become ESM,
 * and the backend is loaded by Neovim as a plain Node script.
 */
export async function importPiCodingAgent(): Promise<PiCodingAgentModule> {
	// SAFETY: `new Function` only knows about the generic `Function` type; the
	// specifier below is the literal peer-dependency path this module requires
	// at runtime, so the resolved module shape matches `PiCodingAgentModule`.
	const dynamicImport = new Function('specifier', 'return import(specifier)') as (
		specifier: string
	) => Promise<PiCodingAgentModule>;
	return dynamicImport('@earendil-works/pi-coding-agent');
}
