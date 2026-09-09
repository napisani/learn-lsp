import * as test from 'node:test';
import * as assert from 'node:assert/strict';

import { textFromMessage } from './completion';

function message(stopReason: string, text = 'hello') {
	return { stopReason, content: [{ type: 'text', text }] };
}

test('textFromMessage returns the text of a natural stop', () => {
	assert.equal(textFromMessage(message('stop')), 'hello');
});

test('textFromMessage accepts a toolUse stop', () => {
	assert.equal(textFromMessage(message('toolUse')), 'hello');
});

test('textFromMessage rejects a truncated response', () => {
	// A 'length' stop landing just after a complete SEARCH/REPLACE block used to
	// return its partial text as a normal result, so the client applied some of
	// a multi-block edit and reported success.
	assert.throws(() => textFromMessage(message('length', 'half a block')), /incomplete/i);
});

test('textFromMessage rejects an aborted response', () => {
	assert.throws(() => textFromMessage(message('aborted')), /incomplete/i);
});

test('textFromMessage reports the provider error message', () => {
	assert.throws(
		() => textFromMessage({ stopReason: 'error', errorMessage: 'rate limited', content: [] }),
		/rate limited/
	);
});

test('textFromMessage joins only text blocks', () => {
	const mixed = {
		stopReason: 'stop',
		content: [
			{ type: 'text', text: 'a' },
			{ type: 'thinking', text: 'ignored' },
			{ type: 'text', text: 'b' },
		],
	};

	assert.equal(textFromMessage(mixed), 'ab');
});
