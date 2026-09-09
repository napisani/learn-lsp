-- The monitor change ring: snapshot diffing, dedup, capping, self-writes.
--
-- Pure by construction -- no timer, no subprocess, no buffer -- which is the
-- point of extracting it from monitor.lua. Every rule here used to be reachable
-- only through underscore-prefixed seams that bypassed the guards a real tick
-- establishes.
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq

local monitor_ring = require("vantage.monitor_ring")
local state = require("vantage.state")

local function change(path, status)
	return { path = path, status = status or " M" }
end

local function touch(root, name, mtime_sec, nsec)
	local path = root .. "/" .. name
	helpers.writefile(path, "x")
	if mtime_sec then
		vim.loop.fs_utime(path, mtime_sec, mtime_sec)
	end
	return path
end

local function fresh(config)
	state.setup({ monitor = config or {} })
	return monitor_ring.new(), helpers.temp_workspace()
end

test("ring seeds without emitting", function()
	local ring, root = fresh()
	local path = touch(root, "a.lua")

	local emitted = ring.absorb({ change(path) }, true)

	eq(#emitted, 0)
	eq(#ring.entries(), 0)
	eq(ring.seeded(), true)
end)

test("ring emits a path new to the change set", function()
	local ring, root = fresh()
	local path = touch(root, "a.lua")
	ring.absorb({}, true)

	local emitted = ring.absorb({ change(path) }, false)

	eq(#emitted, 1)
	eq(ring.entries()[1].path, path)
end)

test("ring records mtime in nanoseconds", function()
	local ring, root = fresh()
	local path = touch(root, "a.lua", 1000)
	ring.absorb({}, true)

	ring.absorb({ change(path) }, false)

	-- Seconds would compare equal for two writes inside one second, silently
	-- losing an agent's second edit to a file it had just touched.
	eq(ring.entries()[1].mtime >= 1000 * 1e9, true)
end)

test("ring detects a sub-second re-edit of an already-modified file", function()
	local ring, root = fresh()
	local path = touch(root, "a.lua", 1000)
	ring.absorb({ change(path) }, true)

	-- Same wall-clock second, later nanosecond.
	vim.loop.fs_utime(path, 1000, 1000)
	local stat = vim.loop.fs_stat(path)
	if not stat or not stat.mtime or (stat.mtime.nsec or 0) == 0 then
		-- Filesystem has no sub-second resolution; the guarantee is untestable
		-- here rather than broken.
		return
	end
	helpers.writefile(path, "y")
	local emitted = ring.absorb({ change(path) }, false)

	eq(#emitted, 1)
end)

test("ring dedupes by path, moving a re-edited file to the front", function()
	local ring, root = fresh()
	local a = touch(root, "a.lua", 1000)
	local b = touch(root, "b.lua", 1000)
	ring.absorb({}, true)
	ring.absorb({ change(a) }, false)
	ring.absorb({ change(a), change(b) }, false)
	vim.loop.fs_utime(a, 3000, 3000)

	ring.absorb({ change(a), change(b) }, false)

	local entries = ring.entries()
	eq(#entries, 2)
	eq(entries[1].path, a)
end)

test("ring caps what it emits, and reports how many it dropped", function()
	local ring, root = fresh({ limit = 2 })
	ring.absorb({}, true)

	local changes = {}
	for index = 1, 5 do
		table.insert(changes, change(touch(root, "f" .. index .. ".lua")))
	end
	local emitted, dropped = ring.absorb(changes, false)

	-- Uncapped, one mass change asked the renderer to open a buffer per file
	-- and wedged the editor.
	eq(#emitted, 2)
	eq(dropped, 3)
	eq(#ring.entries(), 2)
end)

test("ring keeps the newest entries when it caps", function()
	local ring, root = fresh({ limit = 1 })
	ring.absorb({}, true)
	local first = touch(root, "first.lua")
	local last = touch(root, "last.lua")

	local emitted = ring.absorb({ change(first), change(last) }, false)

	eq(#emitted, 1)
	eq(emitted[1].path, last)
end)

test("ring drops a change to a path this instance just wrote", function()
	local ring, root = fresh()
	local path = touch(root, "a.lua")
	ring.absorb({}, true)

	ring.record_self_write(path)
	local emitted = ring.absorb({ change(path) }, false)

	eq(#emitted, 0)
end)

test("ring honors a sub-second self-write grace window", function()
	-- Second-granularity arithmetic made every grace from 1..999 identical.
	local ring, root = fresh({ self_write_grace_ms = 50 })
	local path = touch(root, "a.lua")
	ring.absorb({}, true)

	ring.record_self_write(path, vim.loop.now() - 200)
	local emitted = ring.absorb({ change(path) }, false)

	eq(#emitted, 1)
end)

test("ring keeps a self-written path once the grace window passes", function()
	local ring, root = fresh({ self_write_grace_ms = 0 })
	local path = touch(root, "a.lua")
	ring.absorb({}, true)

	ring.record_self_write(path, vim.loop.now() - 60000)
	local emitted = ring.absorb({ change(path) }, false)

	eq(#emitted, 1)
end)

test("ring clear forgets entries and the baseline", function()
	local ring, root = fresh()
	ring.absorb({}, true)
	ring.absorb({ change(touch(root, "a.lua")) }, false)

	ring.clear()

	eq(#ring.entries(), 0)
	eq(ring.seeded(), false)
end)

test("ring treats a deleted path as mtime 0 so a recreate registers", function()
	local ring, root = fresh()
	local path = root .. "/gone.lua"
	ring.absorb({ change(path, " D") }, true)

	helpers.writefile(path, "back")
	local emitted = ring.absorb({ change(path) }, false)

	eq(#emitted, 1)
end)
