import * as os from 'node:os';
import * as path from 'node:path';
import type { Model } from '@earendil-works/pi-ai';
import type { ModelRuntime } from '@earendil-works/pi-coding-agent';
import { importPiCodingAgent, type PiCodingAgentModule } from './module';

export interface ModelTargetOptions {
	provider: string;
	model: string;
	/** Optional per-model key, registered on the runtime for this call only. */
	apiKey?: string;
	/** `agent.auth.path` from config, if the user set one. */
	authPath?: string;
	/** Base for resolving a relative `authPath`. */
	workspaceRoot?: string;
}

export interface ModelTarget {
	piAgent: PiCodingAgentModule;
	modelRuntime: ModelRuntime;
	model: Model<never>;
}

/**
 * Expands `~` and resolves a configured auth path against the workspace.
 *
 * Exported for tests; the runtimes reach it through `createModelTarget`.
 */
export function resolveAuthPath(authPath: string, workspaceRoot: string): string {
	let expanded = authPath;
	if (authPath === '~') {
		expanded = os.homedir();
	} else if (authPath.startsWith('~/')) {
		expanded = path.join(os.homedir(), authPath.slice(2));
	}
	return path.isAbsolute(expanded) ? path.resolve(expanded) : path.resolve(workspaceRoot, expanded);
}

/**
 * Resolves a provider/model pair to a live Pi `ModelRuntime` and `Model`.
 *
 * This is the *only* thing the agentic and completion runtimes share. Both
 * needed the same four steps -- load the module, create a runtime, register an
 * override key, look the model up -- and each carried its own copy, which is
 * how the completion path ended up silently ignoring `agent.auth.path` while
 * the agentic path honored it.
 *
 * `ModelRuntime.create()` with no argument defaults to `~/.pi/agent/auth.json`
 * and `models.json`: the same files the real `pi` CLI reads and writes, so this
 * stays correct as Pi's own auth format and model catalog evolve rather than
 * being re-derived here.
 */
export async function createModelTarget(options: ModelTargetOptions): Promise<ModelTarget> {
	const piAgent = await importPiCodingAgent();

	const configuredAuthPath = options.authPath?.trim();
	const modelRuntime = await piAgent.ModelRuntime.create(
		configuredAuthPath
			? { authPath: resolveAuthPath(configuredAuthPath, options.workspaceRoot ?? process.cwd()) }
			: undefined
	);

	if (options.apiKey && options.apiKey.trim().length > 0) {
		await modelRuntime.setRuntimeApiKey(options.provider, options.apiKey);
	}

	const model = modelRuntime.getModel(options.provider, options.model);
	if (!model) {
		throw new Error(`Unknown Pi model "${options.provider}/${options.model}".`);
	}

	return {
		piAgent,
		modelRuntime,
		// SAFETY: callers accept any concrete `Model<Api>` returned by
		// `ModelRuntime.getModel`; the SDK declares `Model<never>` only because it
		// erases the provider-specific API type parameter at this boundary.
		model: model as Model<never>,
	};
}
