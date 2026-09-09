import { Data } from 'effect';

export interface ErrorMessageFields {
	readonly message: string;
	readonly cause?: unknown;
}

export class BadRequestError extends Data.TaggedError('BadRequestError')<ErrorMessageFields> {}

export class BackendRuntimeConfigurationError extends Data.TaggedError('BackendRuntimeConfigurationError')<ErrorMessageFields> {}

export class BackendCommandExecutionError extends Data.TaggedError('BackendCommandExecutionError')<ErrorMessageFields & {
	readonly method: string;
}> {}

export class JsonParseError extends Data.TaggedError('JsonParseError')<ErrorMessageFields> {}

export class TraceWriteError extends Data.TaggedError('TraceWriteError')<ErrorMessageFields & {
	readonly path: string;
}> {}

export class CredentialResolutionError extends Data.TaggedError('CredentialResolutionError')<ErrorMessageFields> {}

export class ModelRequestTimedOutError extends Data.TaggedError('ModelRequestTimedOutError')<ErrorMessageFields & {
	readonly timeoutMs: number;
}> {}

export class ModelRequestCancelledError extends Data.TaggedError('ModelRequestCancelledError')<ErrorMessageFields> {}

export class ModelCompletionError extends Data.TaggedError('ModelCompletionError')<ErrorMessageFields> {}

export class EmptyModelResponseError extends Data.TaggedError('EmptyModelResponseError')<ErrorMessageFields> {}

export class UnexpectedModelResponseError extends Data.TaggedError('UnexpectedModelResponseError')<ErrorMessageFields> {}

export function errorMessage(cause: unknown): string {
	return cause instanceof Error ? cause.message : String(cause);
}
