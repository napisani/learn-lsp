-- The change ring behind monitor mode: what changed, in what order, and which
-- changes were this instance's own doing.
--
-- Split out of `monitor.lua` so the part with real rules -- snapshot diffing,
-- mtime comparison, dedup, capping, self-write suppression -- is testable
-- without a timer, a subprocess, or a buffer. `monitor.lua` keeps only the
-- things that genuinely need the event loop. Same pure/impure split as
-- `search_replace.lua` versus `buffer_edit.lua`.
--
-- An instance rather than module state: the previous shape needed four
-- underscore-prefixed test seams to reach its own internals, and those seams
-- bypassed the very guards a real tick establishes.
local state = require("vantage.state")

local M = {}

---@class MonitorEntry
---@field path string absolute path
---@field status string porcelain code
---@field mtime number nanoseconds since epoch, 0 when the path is gone
---@field at integer os.time()

---@class MonitorChange
---@field path string absolute path
---@field status string two-character porcelain code

local function config()
	return state.config.monitor or {}
end

---Modification time in nanoseconds.
---
---Nanoseconds, not seconds: at second granularity two writes to an
---already-modified file inside one wall-clock second compare equal, so the
---second one is absorbed into the snapshot and never emitted on any later tick
---- silently losing an agent's final edit to a file it had just touched.
---@param path string
---@return number
local function mtime_ns(path)
	local stat = vim.loop.fs_stat(path)
	if not stat or not stat.mtime then
		-- A deleted path has no stat; 0 is a stable stand-in that still differs
		-- from any real mtime, so a delete followed by a recreate registers.
		return 0
	end
	return (stat.mtime.sec or 0) * 1e9 + (stat.mtime.nsec or 0)
end

---@return MonitorRing
function M.new()
	---@class MonitorRing
	local ring = {}

	---@type MonitorEntry[] newest-first
	local entries = {}

	---@type table<string, number> path -> mtime_ns as of the previous tick
	local snapshot = {}

	---@type table<string, number> path -> vim.loop.now() when this instance wrote it
	local self_writes = {}

	local function limit()
		return config().limit
	end

	local function grace_ms()
		return config().self_write_grace_ms
	end

	---Inserts newest-first, collapsing any existing entry for the same path.
	---
	---Deduping by path means a file edited three times occupies one slot and
	---moves to the front: this is "recently changed files", not "every write
	---event".
	local function insert_entry(entry)
		for index, existing in ipairs(entries) do
			if existing.path == entry.path then
				table.remove(entries, index)
				break
			end
		end
		table.insert(entries, 1, entry)

		while #entries > limit() do
			table.remove(entries)
		end
	end

	---Whether this instance wrote `path` recently enough that the change is ours.
	---
	---Milliseconds throughout: the previous second-granularity arithmetic made
	---every configured grace from 1 to 999 behave identically.
	local function is_self_write(path, now_ms)
		local at = self_writes[path]
		return at ~= nil and (now_ms - at) <= grace_ms()
	end

	---Drops self-write records past the grace window, so the table cannot grow
	---unbounded across a long session.
	local function prune_self_writes(now_ms)
		for path, at in pairs(self_writes) do
			if (now_ms - at) > grace_ms() then
				self_writes[path] = nil
			end
		end
	end

	---Records a write by this instance.
	---@param path string
	---@param at_ms number? defaults to now
	function ring.record_self_write(path, at_ms)
		self_writes[vim.fn.fnamemodify(path, ":p")] = at_ms or vim.loop.now()
	end

	---Turns one poll's changes into entries.
	---
	---`seed` populates the snapshot without emitting, so toggling the mode on in
	---a dirty worktree does not replay every pre-existing modification as though
	---it had just happened.
	---@param changes MonitorChange[]
	---@param seed boolean
	---@return MonitorEntry[] emitted, oldest first, capped at `limit`
	---@return integer dropped how many emissions the cap discarded
	function ring.absorb(changes, seed)
		local now = os.time()
		local now_ms = vim.loop.now()
		prune_self_writes(now_ms)

		local next_snapshot = {}
		local emitted = {}

		for _, change in ipairs(changes or {}) do
			local mtime = mtime_ns(change.path)
			next_snapshot[change.path] = mtime

			local previous = snapshot[change.path]
			-- New to the set, or touched again since the last tick. The mtime half
			-- is what closes `git status`'s blind spot: an already-modified file
			-- stays modified, so status alone cannot reveal a second edit.
			local changed = previous == nil or mtime > previous
			if changed and not seed and not is_self_write(change.path, now_ms) then
				local entry = {
					path = change.path,
					status = change.status,
					mtime = mtime,
					at = now,
				}
				insert_entry(entry)
				table.insert(emitted, entry)
			end
		end

		snapshot = next_snapshot

		-- Cap what will be rendered. The ring is capped, but the emission list
		-- was not, so one mass change -- a checkout, a stash, a formatter sweep --
		-- asked the renderer to open a buffer per changed file and wedged the
		-- editor. Keep the newest, since those are what the user cares about.
		local dropped = 0
		if #emitted > limit() then
			dropped = #emitted - limit()
			emitted = vim.list_slice(emitted, dropped + 1, #emitted)
		end
		return emitted, dropped
	end

	---Newest-first copy of the ring.
	---@return MonitorEntry[]
	function ring.entries()
		return vim.deepcopy(entries)
	end

	---Forgets everything. Called on stop, so nothing survives the mode.
	function ring.clear()
		entries = {}
		snapshot = {}
		self_writes = {}
	end

	---Test/diagnostic view: whether a baseline snapshot has been taken.
	---@return boolean
	function ring.seeded()
		return next(snapshot) ~= nil
	end

	return ring
end

return M
