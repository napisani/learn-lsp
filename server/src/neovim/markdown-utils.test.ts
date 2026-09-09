import * as test from 'node:test';
import * as assert from 'node:assert/strict';

import { parseSearchReplaceBlocks } from './markdown-utils';

// Canonical aider-style block. The filename sits *before* the fence and the
// git merge-conflict markers sit inside it.
function block(search: string, replace: string, filePath = 'lua/vantage/monitor.lua'): string {
	return [
		filePath,
		'```lua',
		'<<<<<<< SEARCH',
		search,
		'=======',
		replace,
		'>>>>>>> REPLACE',
		'```',
	].join('\n');
}

test('parses a canonical SEARCH/REPLACE block', () => {
	const hunks = parseSearchReplaceBlocks(block('local a = 1', 'local a = 2'));

	assert.equal(hunks.length, 1);
	assert.equal(hunks[0].search, 'local a = 1');
	assert.equal(hunks[0].replace, 'local a = 2');
	assert.equal(hunks[0].filePath, 'lua/vantage/monitor.lua');
});

test('parses multiple blocks from one response', () => {
	const text = [block('local a = 1', 'local a = 2'), block('local b = 3', 'local b = 4')].join('\n\n');

	const hunks = parseSearchReplaceBlocks(text);

	assert.equal(hunks.length, 2);
	assert.equal(hunks[0].search, 'local a = 1');
	assert.equal(hunks[0].replace, 'local a = 2');
	assert.equal(hunks[1].search, 'local b = 3');
	assert.equal(hunks[1].replace, 'local b = 4');
});

test('a bare nested code fence in the replace body does not terminate the block', () => {
	// This is avante issue #832. The fences here are BARE, at the start of the
	// line -- commented ones (`-- ```lua`) would not exercise a fence-splitting
	// parser at all, since they do not read as fences.
	const replace = ['/**', ' * Example:', '```lua', 'local x = 1', '```', ' */', 'local a = 2'].join('\n');
	const hunks = parseSearchReplaceBlocks(block('local a = 1', replace));

	assert.equal(hunks.length, 1);
	assert.equal(hunks[0].replace, replace);
});

test('a bare nested fence in the search body does not terminate the block', () => {
	const search = ['```lua', 'local a = 1', '```'].join('\n');
	const hunks = parseSearchReplaceBlocks(block(search, 'local a = 2'));

	assert.equal(hunks.length, 1);
	assert.equal(hunks[0].search, search);
});

test('extracts blocks surrounded by prose', () => {
	// Models editorialize even when told not to.
	const text = [
		"Here's what I'd change, and why it matters:",
		'',
		block('local a = 1', 'local a = 2'),
		'',
		'That keeps the interval configurable.',
	].join('\n');

	const hunks = parseSearchReplaceBlocks(text);

	assert.equal(hunks.length, 1);
	assert.equal(hunks[0].replace, 'local a = 2');
});

test('parses a block with no fence at all', () => {
	// The markers are the contract; the fence is decoration a model may omit.
	const text = ['<<<<<<< SEARCH', 'local a = 1', '=======', 'local a = 2', '>>>>>>> REPLACE'].join('\n');

	const hunks = parseSearchReplaceBlocks(text);

	assert.equal(hunks.length, 1);
	assert.equal(hunks[0].search, 'local a = 1');
	assert.equal(hunks[0].filePath, undefined);
});

test('rejects an unterminated block rather than truncating it', () => {
	const text = ['<<<<<<< SEARCH', 'local a = 1', '=======', 'local a = 2'].join('\n');

	// Silently treating this as a complete hunk would apply a replacement the
	// model never finished writing.
	assert.throws(() => parseSearchReplaceBlocks(text), /unterminated/i);
});

test('rejects a block with no divider', () => {
	const text = ['<<<<<<< SEARCH', 'local a = 1', '>>>>>>> REPLACE'].join('\n');

	assert.throws(() => parseSearchReplaceBlocks(text), /divider|=======/i);
});

test('rejects an empty SEARCH body', () => {
	// aider uses an empty SEARCH to mean "create a new file"; Vantage never
	// creates files, so this can only be a malformed edit.
	assert.throws(() => parseSearchReplaceBlocks(block('', 'local a = 2')), /empty/i);
});

test('accepts an empty REPLACE body as a deletion', () => {
	const hunks = parseSearchReplaceBlocks(block('local a = 1', ''));

	assert.equal(hunks.length, 1);
	assert.equal(hunks[0].replace, '');
});

test('normalizes CRLF line endings', () => {
	const text = block('local a = 1', 'local a = 2').replace(/\n/g, '\r\n');

	const hunks = parseSearchReplaceBlocks(text);

	assert.equal(hunks[0].search, 'local a = 1');
	assert.equal(hunks[0].replace, 'local a = 2');
});

test('preserves interior blank lines and indentation verbatim', () => {
	// SEARCH text has to match the buffer byte-for-byte modulo the ladder's
	// whitespace tolerance, so the parser must not trim or collapse anything.
	const search = ['function M.f()', '', '\treturn 1', 'end'].join('\n');
	const hunks = parseSearchReplaceBlocks(block(search, 'function M.f() return 2 end'));

	assert.equal(hunks[0].search, search);
});

test('returns no hunks for text containing no blocks', () => {
	assert.deepEqual(parseSearchReplaceBlocks('I could not find anything to change.'), []);
});

test('reads the filename from the line above the fence', () => {
	const hunks = parseSearchReplaceBlocks(block('local a = 1', 'local a = 2', 'server/src/app.ts'));

	assert.equal(hunks[0].filePath, 'server/src/app.ts');
});
