import * as test from 'node:test';
import * as assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseWalkthroughFallback } from './submit-tools';

const workspaces: string[] = [];

test.afterEach(() => {
	for (const workspace of workspaces.splice(0)) {
		rmSync(workspace, { recursive: true, force: true });
	}
});

test('parseWalkthroughFallback validates assistant JSON against the submit_walkthrough contract', () => {
	const workspace = mkdtempSync(join(tmpdir(), 'vantage-walkthrough-'));
	workspaces.push(workspace);
	writeFileSync(join(workspace, 'calculator.lua'), 'local M = {}\nreturn M\n');

	const pointers = parseWalkthroughFallback(workspace, JSON.stringify({
		pointers: [{
			file: 'calculator.lua',
			line: 1,
			anchor: 'local M = {}',
			description: 'Initializes the calculator module table.',
		}],
	}));

	assert.deepEqual(pointers, [{
		file: 'calculator.lua',
		line: 1,
		anchor: 'local M = {}',
		description: 'Initializes the calculator module table.',
	}]);
});
