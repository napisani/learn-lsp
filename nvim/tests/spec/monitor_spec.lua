-- Monitor mode: the change ring and self-write suppression.
--
-- Driven entirely through monitor._absorb and monitor_source.fake, so no test
-- here spawns git or a timer.
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq

local monitor = require("vantage.monitor")
local monitor_source = require("vantage.monitor_source")
local state = require("vantage.state")

local function change(path, status)
	return { path = path, status = status or " M" }
end

---A real file, since absorb() stats every reported path for its mtime.
local function touch(root, name, mtime)
	local path = root .. "/" .. name
	helpers.writefile(path, "x")
	if mtime then
		vim.loop.fs_utime(path, mtime, mtime)
	end
	return path
end

local function reset()
	monitor.stop()
	state.setup({})
end

test("monitor seeds the first poll without emitting pre-existing changes", function()
	reset()
	local root = helpers.temp_workspace()
	local path = touch(root, "a.lua")

	local emitted = monitor._ring().absorb({ change(path) }, true)

	-- Toggling the mode on in a dirty worktree must not dump every existing
	-- modification into the feed as though it had just happened.
	eq(#emitted, 0)
	eq(#monitor.entries(), 0)
end)

test("monitor emits a path new to the change set", function()
	reset()
	local root = helpers.temp_workspace()
	local path = touch(root, "a.lua")

	monitor._ring().absorb({}, true)
	local emitted = monitor._ring().absorb({ change(path, false) })

	eq(#emitted, 1)
	eq(monitor.entries()[1].path, path)
end)

test("monitor emits an already-modified path whose mtime advanced", function()
	reset()
	local root = helpers.temp_workspace()
	local path = touch(root, "a.lua", 1000)

	monitor._ring().absorb({ change(path) }, true)
	-- git status still reports the same code; only the mtime reveals the second
	-- edit. This is the blind spot the stat exists to close.
	vim.loop.fs_utime(path, 2000, 2000)
	local emitted = monitor._ring().absorb({ change(path, false) })

	eq(#emitted, 1)
end)

test("monitor ignores an already-modified path whose mtime did not move", function()
	reset()
	local root = helpers.temp_workspace()
	local path = touch(root, "a.lua", 1000)

	monitor._ring().absorb({ change(path) }, true)
	local emitted = monitor._ring().absorb({ change(path, false) })

	eq(#emitted, 0)
end)

test("monitor dedupes by path, moving a re-edited file to the front", function()
	reset()
	local root = helpers.temp_workspace()
	local a = touch(root, "a.lua", 1000)
	local b = touch(root, "b.lua", 1000)

	monitor._ring().absorb({}, true)
	monitor._ring().absorb({ change(a, false) })
	monitor._ring().absorb({ change(a, false), change(b) })
	vim.loop.fs_utime(a, 3000, 3000)
	monitor._ring().absorb({ change(a, false), change(b) })

	local entries = monitor.entries()
	-- One slot per file: the ring is "recently changed files", not every event.
	eq(#entries, 2)
	eq(entries[1].path, a)
	eq(entries[2].path, b)
end)

test("monitor applies the configured limit", function()
	reset()
	state.setup({ monitor = { limit = 2 } })
	local root = helpers.temp_workspace()

	monitor._ring().absorb({}, true)
	for index = 1, 4 do
		monitor._ring().absorb({ change(touch(root, "f" .. index .. ".lua", false)) })
	end

	eq(#monitor.entries(), 2)
end)

test("monitor drops a change to a path this instance just wrote", function()
	reset()
	local root = helpers.temp_workspace()
	local path = touch(root, "a.lua")

	monitor._ring().absorb({}, true)
	monitor._ring().record_self_write(path)
	local emitted = monitor._ring().absorb({ change(path, false) })

	eq(#emitted, 0)
	eq(#monitor.entries(), 0)
end)

test("monitor keeps a change to a path written outside the grace window", function()
	reset()
	state.setup({ monitor = { self_write_grace_ms = 0 } })
	local root = helpers.temp_workspace()
	local path = touch(root, "a.lua")

	monitor._ring().absorb({}, true)
	monitor._ring().record_self_write(path, vim.loop.now() - 60000)
	local emitted = monitor._ring().absorb({ change(path, false) })

	eq(#emitted, 1)
end)

test("monitor stop clears the ring and reports inactive", function()
	reset()
	local root = helpers.temp_workspace()
	monitor.start({ workspace = root, source = monitor_source.fake({}), render = function() end })
	monitor._ring().absorb({}, true)
	monitor._ring().absorb({ change(touch(root, "a.lua", false)) })

	eq(monitor.is_active(), true)
	monitor.stop()

	eq(monitor.is_active(), false)
	eq(#monitor.entries(), 0)
	eq(monitor.workspace(), nil)
end)

test("monitor stop runs on_stop and is safe to call twice", function()
	reset()
	local torn = 0
	monitor.start({
		workspace = helpers.temp_workspace(),
		source = monitor_source.fake({}),
		render = function() end,
		on_stop = function()
			torn = torn + 1
		end,
	})

	monitor.stop()
	monitor.stop()

	eq(torn, 1)
end)

test("monitor start is refused while already active", function()
	reset()
	local opts = {
		workspace = helpers.temp_workspace(),
		source = monitor_source.fake({}),
		render = function() end,
	}
	monitor.start(opts)

	eq(monitor.start(opts), false)

	monitor.stop()
end)
