-- NDJSON persistence for prompt history: round-trip, corrupt lines, compaction
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq
local writefile = helpers.writefile

local history_store = require("vantage.history_store")

local function temp_path()
	return vim.fn.tempname() .. "/vantage/prompt-history.ndjson"
end

local function entry(text)
	return { kind = "question", text = text, workspaceRoot = "/w", submitted = true, timestamp = 1 }
end

test("store append then load round-trips an entry", function()
	local store = history_store.ndjson(temp_path())

	eq(store.append(entry("round trip")), true)

	local entries, skipped = store.load()
	eq(#entries, 1)
	eq(entries[1].text, "round trip")
	eq(skipped, 0)
end)

test("store append creates the parent directory", function()
	local path = temp_path()
	local store = history_store.ndjson(path)

	store.append(entry("nested"))

	eq(vim.fn.filereadable(path), 1)
end)

test("store load preserves append order, oldest first", function()
	local store = history_store.ndjson(temp_path())
	store.append(entry("first"))
	store.append(entry("second"))

	local entries = store.load()
	eq(entries[1].text, "first")
	eq(entries[2].text, "second")
end)

test("store load skips a corrupt line and keeps the valid ones", function()
	local path = temp_path()
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	writefile(
		path,
		vim.json.encode(entry("before"))
			.. "\n{ this is not json\n"
			.. vim.json.encode(entry("after"))
			.. "\n"
	)

	local entries, skipped = history_store.ndjson(path).load()

	eq(#entries, 2)
	eq(entries[1].text, "before")
	eq(entries[2].text, "after")
	eq(skipped, 1)
end)

test("store load skips a decodable line that is not an entry", function()
	local path = temp_path()
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	-- Valid JSON, wrong shape: must not become a textless entry.
	writefile(path, '{"unrelated":true}\n' .. vim.json.encode(entry("real")) .. "\n")

	local entries, skipped = history_store.ndjson(path).load()

	eq(#entries, 1)
	eq(entries[1].text, "real")
	eq(skipped, 1)
end)

test("store load of a missing file is empty rather than an error", function()
	local entries, skipped = history_store.ndjson(temp_path()).load()

	eq(#entries, 0)
	eq(skipped, 0)
end)

test("store rewrite replaces the whole file", function()
	local store = history_store.ndjson(temp_path())
	store.append(entry("gone"))

	store.rewrite({ entry("kept") })

	local entries = store.load()
	eq(#entries, 1)
	eq(entries[1].text, "kept")
end)

test("store rewrite with no entries empties the file", function()
	local store = history_store.ndjson(temp_path())
	store.append(entry("gone"))

	store.rewrite({})

	eq(#store.load(), 0)
end)

test("store append to an unwritable path reports failure instead of raising", function()
	-- A path whose parent is an existing *file* cannot be created as a directory.
	local blocker = vim.fn.tempname()
	writefile(blocker, "not a directory\n")
	local store = history_store.ndjson(blocker .. "/history.ndjson")

	local ok, err = store.append(entry("nope"))

	eq(ok, false)
	assert(err ~= nil, "expected an error message")
end)

test("store compacts only once the file exceeds the retention factor", function()
	local store = history_store.ndjson(temp_path())

	eq(store.should_compact(40, 50), false)
	eq(store.should_compact(200, 50), false)
	eq(store.should_compact(201, 50), true)
end)

test("fake store satisfies the same contract", function()
	local store = history_store.fake()

	eq(store.append(entry("not persisted")), true)
	local entries = store.load()
	eq(#entries, 1)
	eq(entries[1].text, "not persisted")

	store.rewrite({})
	eq(#store.load(), 0)
end)

test("appended rows carry a schema version so a future field change can migrate", function()
	local path = temp_path()
	history_store.ndjson(path).append(entry("versioned"))

	local decoded = vim.json.decode(vim.fn.readfile(path)[1])
	eq(decoded.v, 1)
end)

test("store creates the file and its directory unreadable to other users", function()
	local path = temp_path()
	history_store.ndjson(path).append(entry("private"))

	-- Prompt text and abandoned drafts must not be world-readable.
	eq(vim.fn.getfperm(path), "rw-------")
	local dir_perm = vim.fn.getfperm(vim.fn.fnamemodify(path, ":h"))
	assert(dir_perm:sub(4) == "------", "expected a private directory, got " .. dir_perm)
end)

test("a failed rewrite leaves the existing file intact", function()
	local path = temp_path()
	local store = history_store.ndjson(path)
	store.append(entry("must survive"))

	-- Block the temp file the rewrite stages through, so the write fails after
	-- the point where a truncating "w" on the live path would already have
	-- destroyed the history.
	vim.fn.mkdir(path .. ".tmp", "p")
	local ok = store.rewrite({ entry("replacement") })

	eq(ok, false)
	local entries = store.load()
	eq(#entries, 1)
	eq(entries[1].text, "must survive")
end)

test("store load distinguishes an unreadable file from an empty one", function()
	local blocked = vim.fn.tempname()
	vim.fn.mkdir(blocked, "p")   -- a directory where a file is expected

	local entries, skipped, read_failed = history_store.ndjson(blocked).load()

	eq(#entries, 0)
	eq(read_failed, true)
	eq(skipped, 0)
end)

test("store load reports a missing file as empty rather than failed", function()
	local entries, _, read_failed = history_store.ndjson(temp_path()).load()

	eq(#entries, 0)
	eq(read_failed, false)
end)

test("store load normalizes rows with wrongly-typed fields", function()
	local path = temp_path()
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	writefile(path, '{"text":"odd","workspaceRoot":{},"kind":7,"submitted":"yes"}\n')

	local entries, skipped = history_store.ndjson(path).load()

	eq(#entries, 1)
	eq(entries[1].workspaceRoot, "")
	eq(entries[1].kind, "prompt")
	eq(entries[1].submitted, true)
	eq(skipped, 0)
end)
