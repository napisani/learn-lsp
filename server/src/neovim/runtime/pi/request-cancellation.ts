/** One cancellation signal spans session discovery/setup and the prompt itself. */
export function requestCancellation(
	parent: AbortSignal | undefined,
	timeoutMs: number | undefined,
	abortSession: () => Promise<void>,
) {
	const controller = new AbortController();
	const abort = async () => {
		controller.abort(new Error('Vantage agent request cancelled.'));
		await abortSession();
	};
	const listener = () => {
		void abort();
	};
	parent?.addEventListener('abort', listener, { once: true });
	if (parent?.aborted) {
		controller.abort(parent.reason);
	}
	const timeout = timeoutMs && timeoutMs > 0 ? setTimeout(listener, timeoutMs) : undefined;
	return {
		signal: controller.signal,
		abort,
		dispose: () => {
			if (timeout) {
				clearTimeout(timeout);
			}
			parent?.removeEventListener('abort', listener);
		},
	};
}
