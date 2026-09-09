-- Monitor change detection: porcelain parsing and hunk location.
--
-- The parsing tests are pure. The git-backed tests build their own throwaway
-- repository, so they are the only place in the suite that spawns git.
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq

local monitor_source = require("vantage.monitor_source")

test("source parses modified, added, untracked and deleted entries", function()
	local changes = monitor_source.parse(" M lua/a.lua\nA  lua/b.lua\n?? c.txt\n D d.txt\n", "/w")

	eq(#changes, 4)
	eq(changes[1], { status = " M", path = "/w/lua/a.lua" })
	eq(changes[2], { status = "A ", path = "/w/lua/b.lua" })
	eq(changes[3], { status = "??", path = "/w/c.txt" })
	eq(changes[4], { status = " D", path = "/w/d.txt" })
end)

test("source takes the new path from a rename entry", function()
	local changes = monitor_source.parse("R  old.lua -> new.lua\n", "/w")

	-- The new path is what exists on disk; opening the old one would fail.
	eq(#changes, 1)
	eq(changes[1].path, "/w/new.lua")
end)

test("source skips blank and truncated lines", function()
	local changes = monitor_source.parse("\n M\n M a.lua\n", "/w")

	eq(#changes, 1)
	eq(changes[1].path, "/w/a.lua")
end)

test("source parse of empty output yields no changes", function()
	eq(#monitor_source.parse("", "/w"), 0)
	eq(#monitor_source.parse(nil, "/w"), 0)
end)

---Builds a real repository with one committed file, then modifies it.
---@return string? root nil when git is unavailable
local function git_workspace()
	local root = vim.fn.tempname()
	vim.fn.mkdir(root, "p")
	local function git(...)
		return vim.fn.system({ "git", "-C", root, ... })
	end
	git("init", "-q")
	if vim.v.shell_error ~= 0 then
		return nil
	end
	git("config", "user.email", "test@example.com")
	git("config", "user.name", "Test")
	helpers.writefile(root .. "/a.lua", "one\ntwo\nthree\nfour\n")
	git("add", "-A")
	git("commit", "-qm", "init")
	return root
end

---Drives an async callback to completion inside a headless run.
local function await(start)
	local done, value = false, nil
	start(function(result)
		value = result
		done = true
	end)
	vim.wait(5000, function()
		return done
	end, 20)
	return done, value
end

test("source poll reports a modified file from a real repository", function()
	local root = git_workspace()
	if not root then
		return
	end
	helpers.writefile(root .. "/a.lua", "one\nCHANGED\nthree\nfour\n")

	local done, changes = await(function(cb)
		monitor_source.git(root).poll(function(result)
			cb(result)
		end)
	end)

	eq(done, true)
	eq(#changes, 1)
	eq(vim.fn.fnamemodify(changes[1].path, ":t"), "a.lua")
end)

test("source poll reports a terminal error outside a repository", function()
	local root = vim.fn.tempname()
	vim.fn.mkdir(root, "p")

	local done, err = await(function(cb)
		monitor_source.git(root).poll(function(_, error_message)
			cb(error_message)
		end)
	end)

	eq(done, true)
	-- Terminal, not transient: the caller stops the mode rather than retrying
	-- against a directory that will never be a repository.
	assert(err ~= nil, "expected an error message outside a repository")
end)

test("source first_hunk finds the first changed line", function()
	local root = git_workspace()
	if not root then
		return
	end
	helpers.writefile(root .. "/a.lua", "one\ntwo\nCHANGED\nfour\n")

	local done, line = await(function(cb)
		monitor_source.first_hunk(root, root .. "/a.lua", cb)
	end)

	eq(done, true)
	eq(line, 3)
end)

test("source first_hunk degrades to nil rather than raising outside a repository", function()
	local root = vim.fn.tempname()
	vim.fn.mkdir(root, "p")

	local done, line = await(function(cb)
		monitor_source.first_hunk(root, root .. "/missing.lua", cb)
	end)

	eq(done, true)
	-- Hunk position is an enhancement, never a precondition for showing a file.
	eq(line, nil)
end)

test("fake source replays queued ticks then repeats the last", function()
	local source = monitor_source.fake({
		{ { path = "/w/a.lua", status = " M" } },
		{ { path = "/w/b.lua", status = " M" } },
	})

	local seen = {}
	for _ = 1, 3 do
		source.poll(function(changes)
			table.insert(seen, changes[1].path)
		end)
	end

	eq(seen, { "/w/a.lua", "/w/b.lua", "/w/b.lua" })
	eq(source._polls(), 3)
end)

test("source keeps a filename that legitimately contains an arrow", function()
	-- The rename split used to run on every status, truncating any path with
	-- " -> " in it down to whatever followed the arrow.
	local changes = monitor_source.parse(" M docs/a -> b.md\n", "/w")

	eq(#changes, 1)
	eq(changes[1].path, "/w/docs/a -> b.md")
end)

test("source still takes the new path for a copy entry", function()
	local changes = monitor_source.parse("C  old.lua -> copy.lua\n", "/w")

	eq(changes[1].path, "/w/copy.lua")
end)

test("first_hunk returns a killable handle", function()
	local root = git_workspace()
	if not root then
		return
	end
	helpers.writefile(root .. "/a.lua", "one\nCHANGED\n")

	local handle = monitor_source.first_hunk(root, root .. "/a.lua", function() end)

	-- The caller needs this to kill a `git diff` it has given up on.
	assert(handle ~= nil, "expected a subprocess handle")
	assert(type(handle.kill) == "function", "expected the handle to be killable")
	pcall(handle.kill, handle, "sigterm")
end)
