import * as readline from 'node:readline';
import { z } from 'zod';
import { Effect } from 'effect';
import { handleBackendRequestEffect } from './handlers';
import { parseBackendRequest } from './protocol';
import { BadRequestError, errorMessage, JsonParseError } from './effect-errors';
import type { AgentRuntimeProgress, BackendRequest, BackendResponse } from './protocol';
import type { JsonValue } from './utils';

const writeResponse = (response: BackendResponse): void => {
	process.stdout.write(`${JSON.stringify(response)}\n`);
};

const writeProgress = (id: string, progress: AgentRuntimeProgress): void => {
	process.stdout.write(`${JSON.stringify({ id, type: 'progress', progress })}\n`);
};

const interfaceReader = readline.createInterface({
	input: process.stdin,
	crlfDelay: Infinity,
});

const inFlight = new Map<string, AbortController>();

const CancelRequestSchema = z.object({
	method: z.literal('cancelRequest'),
	params: z.unknown().optional(),
});

const CancelRequestParamsSchema = z.object({ id: z.string() });

function tryHandleCancel(raw: JsonValue): boolean {
	const cancelRequest = CancelRequestSchema.safeParse(raw);
	if (!cancelRequest.success) {
		return false;
	}

	const params = CancelRequestParamsSchema.safeParse(cancelRequest.data.params);
	if (params.success) {
		inFlight.get(params.data.id)?.abort();
	}
	return true;
}

interfaceReader.on('line', (line) => {
	void Effect.runPromise(handleLineEffect(line));
});

function handleLineEffect(line: string): Effect.Effect<void> {
	let requestId = 'unknown';

	return Effect.gen(function* () {
		if (line.trim().length === 0) {
			return;
		}

		const raw = yield* parseJsonLineEffect(line);
		if (tryHandleCancel(raw)) {
			return;
		}

		const request = yield* parseRequestEffect(raw);
		requestId = request.id;
		const controller = new AbortController();
		yield* Effect.sync(() => {
			inFlight.set(request.id, controller);
		});
		const response = yield* handleBackendRequestEffect(request, undefined, {
			signal: controller.signal,
			reportProgress: (progress) => {
				writeProgress(request.id, progress);
			},
		}).pipe(
			Effect.ensuring(Effect.sync(() => {
				inFlight.delete(request.id);
			}))
		);
		yield* writeResponseEffect(response);
	}).pipe(
		Effect.catchAll((error) => writeResponseEffect(badRequestResponse(requestId, error))),
		Effect.catchAllDefect((defect) => writeResponseEffect(badRequestResponse(requestId, defect)))
	);
}

function parseJsonLineEffect(line: string): Effect.Effect<JsonValue, JsonParseError> {
	return Effect.try({
		try: () => {
			const parsed: JsonValue = JSON.parse(line);
			return parsed;
		},
		catch: (cause) => new JsonParseError({
			message: errorMessage(cause),
			cause,
		}),
	});
}

function parseRequestEffect(raw: JsonValue): Effect.Effect<BackendRequest, BadRequestError> {
	return Effect.try({
		try: () => parseBackendRequest(raw),
		catch: (cause) => new BadRequestError({
			message: errorMessage(cause),
			cause,
		}),
	});
}

function writeResponseEffect(response: BackendResponse): Effect.Effect<void> {
	return Effect.sync(() => {
		writeResponse(response);
	});
}

function badRequestResponse(id: string, cause: unknown): BackendResponse {
	return {
		id,
		ok: false,
		error: {
			code: 'bad_request',
			message: errorMessage(cause),
		},
	};
}
