// Pi provider/model defaults, shared by both runtimes.
//
// Previously the agentic runtime named these as private constants and the
// completion factory inlined the same two literals, so the two runtimes could
// silently disagree about what "unset model" means after any future change --
// the same divergence class that let `agent.auth.path` apply to only one of them.
export const DEFAULT_PROVIDER = 'openai';
export const DEFAULT_MODEL = 'gpt-4o-mini';
