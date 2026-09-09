-- Monitor mode: a live feed of workspace edits made by something other than
-- this Neovim instance -- in practice, an agent running in an adjacent pane.
--
-- This module owns only what genuinely needs the event loop: the poll timer,
-- the in-flight guards on both the poll and the render side, the run token, and
-- lifecycle. The rules about *what changed* live in `monitor_ring.lua`, which is
-- testable without a timer or a subprocess.
--
-- Detection comes in through `opts.source` and presentation goes out through
-- `opts.render`, both supplied by commands.lua. There is deliberately no
-- cycling: the default renderer opens each changed file, which Vim already
-- records as a jump, so <C-o>/<C-i> walk the trail natively.
local state = require("vantage.state")
local monitor_ring = require("vantage.monitor_ring")
local monitor_source = require("vantage.monitor_source")

local M = {}

---@class MonitorRenderContext
---@field path string absolute path to the changed file
---@field status string two-character git porcelain code
---@field workspace string workspace root the mode is watching
---@field line integer? first changed line, nil when unknown or not applicable
---@field deleted boolean the path no longer exists on disk

---@type MonitorRing
local ring = monitor_ring.new()

local timer = nil
local active = false

---The poll currently in flight, as `{ seq, at, handle }`, or nil.
---
---A poll slower than `interval_ms` used to stack: the timer kept firing and each
---tick spawned another `git status`, without bound. Measured at a 20ms interval
---against a source that never answered, 29 subprocesses piled up in 600ms, each
---holding pipe file descriptors.
local pending = nil
local poll_seq = 0

---The render drain currently in flight, as `{ handle }`, or nil.
---
---The poll guard alone was not enough. `answered` clears `pending` before
---draining, so the next tick was free to start a *second* concurrent drain while
---the first awaited its hunk lookup -- interleaving renders and scrambling
---exactly the jumplist ordering the sequential drain exists to protect.
local draining = nil

---Incremented on every start and stop. Async callbacks capture it and drop
---themselves if it has moved on, so work from a previous run cannot act on a
---later one.
local generation = 0
local started_opts = nil
local workspace = nil

---Whether a baseline poll has completed. Tracked separately from "have we
---ticked once", because an abandoned seeding poll would otherwise leave the
---snapshot empty and make the next tick emit the entire dirty worktree.
local seeded = false

---How many consecutive polls have failed. A single `git status` failure is not
---proof the repository is unusable -- index.lock contention and mid-rebase
---states resolve on their own -- so the mode retries before giving up.
local consecutive_failures = 0
local MAX_CONSECUTIVE_FAILURES = 3

---@type table<string, number> warning key -> vim.loop.now() when last announced
local warned = {}

local write_augroup = nil

local function config()
	return state.config.monitor or {}
end

---Announces `message` at most once per `warn_cooldown_ms` per key.
---
---A cooldown rather than once-per-session: suppressing forever meant a
---`poll_timeout` recurring every 30 seconds -- the wedged-filesystem case the
---timeout exists for -- was announced one time and then degraded in silence.
local function warn_throttled(key, message)
	local now = vim.loop.now()
	local last = warned[key]
	if last and (now - last) < config().warn_cooldown_ms then
		return
	end
	warned[key] = now
	vim.notify("Vantage monitor: " .. message, vim.log.levels.WARN)
end

---Kills and forgets the in-flight poll, if any. Killing matters as much as
---forgetting: dropping the callback alone leaves the subprocess and its pipes
---alive for the rest of the session.
local function abandon_pending()
	if not pending then
		return
	end
	local handle = pending.handle
	pending = nil
	if handle and type(handle.kill) == "function" then
		pcall(handle.kill, handle, "sigterm")
	end
end

---Same, for the hunk lookup a drain is waiting on.
local function abandon_draining()
	if not draining then
		return
	end
	local handle = draining.handle
	draining = nil
	if handle and type(handle.kill) == "function" then
		pcall(handle.kill, handle, "sigterm")
	end
end

---@return boolean
function M.is_active()
	return active
end

---Newest-first recently changed files.
---@return MonitorEntry[]
function M.entries()
	return ring.entries()
end

---@return string? workspace root the mode was started against
function M.workspace()
	return workspace
end

---Health snapshot, for `:VantageStatus` and tests.
---
---Exists because there was previously no way to tell a healthy quiet repository
---from a mode that had been failing since minute two.
---@return { active: boolean, polling: boolean, draining: boolean, seeded: boolean, consecutive_failures: integer, entries: integer }
function M.health()
	return {
		active = active,
		polling = pending ~= nil,
		draining = draining ~= nil,
		seeded = seeded,
		consecutive_failures = consecutive_failures,
		entries = #ring.entries(),
	}
end

---Builds the table handed to the renderer.
---
---A single table rather than positional arguments so the contract can gain
---fields -- a diff view will want more than a path -- without breaking every
---configured renderer that already exists.
---@param entry MonitorEntry
---@return MonitorRenderContext
local function render_context(entry)
	return {
		path = entry.path,
		status = entry.status,
		workspace = workspace,
		line = nil,
		deleted = (entry.status or ""):find("D", 1, true) ~= nil or vim.loop.fs_stat(entry.path) == nil,
	}
end

---Renders `queue` in order, resolving each entry's changed line first.
---
---Sequential, and rendering *every* entry rather than only the newest: the
---default renderer opens each file, and that is what lays down the jumplist
---trail <C-o> walks. Racing the hunk lookups would scramble the trail into an
---order the files never changed in.
---@param queue MonitorEntry[] oldest first
---@param index integer?
local function drain(queue, index)
	index = index or 1
	local entry = queue[index]
	if not entry then
		draining = nil
		return
	end

	local run = generation
	local context = render_context(entry)
	-- One-shot latch. Without it, a source whose `first_hunk` answers and *then*
	-- raises would render this entry twice and double-advance the drain.
	local answered_once = false

	local function present(line)
		if answered_once then
			return
		end
		answered_once = true
		if not active or generation ~= run then
			draining = nil
			return
		end
		draining = nil
		context.line = line
		local render = started_opts and started_opts.render
		if render then
			local ok, err = pcall(render, context)
			if not ok then
				warn_throttled("render", "renderer failed (" .. tostring(err) .. ")")
				M.stop()
				return
			end
		end
		drain(queue, index + 1)
	end

	local source = started_opts and started_opts.source
	-- A deleted path has no diff, and a source is free not to offer hunks at
	-- all -- in both cases the renderer simply gets no line.
	if context.deleted or not source or type(source.first_hunk) ~= "function" then
		present(nil)
		return
	end

	local ok, handle = pcall(source.first_hunk, entry.path, present)
	if not ok then
		present(nil)
		return
	end
	if not answered_once then
		draining = { handle = handle }
	end
end

local function tick(seed)
	local source = started_opts and started_opts.source
	if not source then
		return
	end

	if draining then
		-- A drain is still walking its queue. Issuing a poll now could start a
		-- second concurrent drain and interleave its renders with this one's.
		return
	end

	if pending then
		if (vim.loop.now() - pending.at) < config().poll_timeout_ms then
			-- Skipping this tick is the whole guard: issuing another poll would
			-- stack subprocesses one per tick for as long as the slow poll lasts.
			return
		end
		warn_throttled("poll_timeout", "a poll exceeded " .. config().poll_timeout_ms .. "ms and was abandoned")
		abandon_pending()
	end

	local run = generation
	poll_seq = poll_seq + 1
	local seq = poll_seq
	pending = { seq = seq, at = vim.loop.now() }

	local function answered(changes, err)
		-- Valid only while still *the* pending poll. Every way a poll dies --
		-- stop(), a restart, an abandon, a prior answer -- clears or replaces
		-- `pending`, so this one identity check covers stale runs and late
		-- answers alike.
		if pending == nil or pending.seq ~= seq or generation ~= run then
			return
		end
		pending = nil

		if err then
			consecutive_failures = consecutive_failures + 1
			if consecutive_failures >= MAX_CONSECUTIVE_FAILURES then
				warn_throttled("poll", err .. "; monitor stopped after " .. consecutive_failures .. " failures")
				M.stop()
			else
				-- Transient by assumption: `git status` refreshes the index and
				-- fails while another git process holds index.lock, which is
				-- exactly what an adjacent agent causes. Retry on the next tick.
				warn_throttled("poll_retry", err .. "; retrying")
			end
			return
		end
		consecutive_failures = 0

		local ok, emitted, dropped = pcall(ring.absorb, changes or {}, seed)
		if not ok then
			warn_throttled("absorb", "could not process changes (" .. tostring(emitted) .. ")")
			M.stop()
			return
		end
		if seed then
			seeded = true
		end
		if dropped and dropped > 0 then
			warn_throttled(
				"dropped",
				dropped .. " change(s) beyond the " .. config().limit .. "-entry cap were not opened"
			)
		end
		drain(emitted)
	end

	-- pcall so a source that raises synchronously cannot escape into the timer
	-- callback. `stop()` clears `pending`, so the guard above cannot be wedged.
	local issued, handle = pcall(source.poll, answered)
	if not issued then
		warn_throttled("poll", "source failed (" .. tostring(handle) .. "); monitor stopped")
		M.stop()
		return
	end
	if pending and pending.seq == seq then
		pending.handle = handle
	end
end

---Records this instance's own writes, so an edit the user makes here is not
---replayed back at them as though the agent had made it.
local function watch_own_writes()
	write_augroup = vim.api.nvim_create_augroup("VantageMonitorWrites", { clear = true })
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = write_augroup,
		callback = function(args)
			local path = vim.api.nvim_buf_get_name(args.buf)
			if path ~= "" then
				ring.record_self_write(path)
			end
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = write_augroup,
		callback = function()
			M.stop()
		end,
	})
end

---Starts the mode.
---@param opts { source: table, render: fun(context: MonitorRenderContext), on_stop: fun()?, workspace: string? }
---@return boolean started
function M.start(opts)
	if active then
		return false
	end

	started_opts = opts or {}
	workspace = started_opts.workspace
	ring.clear()
	pending = nil
	draining = nil
	seeded = false
	consecutive_failures = 0
	warned = {}
	active = true
	generation = generation + 1

	watch_own_writes()

	-- The first poll only seeds the baseline; see monitor_ring.absorb.
	tick(true)

	-- That tick can terminate the mode synchronously (a source that raises, or
	-- one that answers with an error immediately). Creating a timer afterwards
	-- would orphan a uv handle no later stop() could reach, and report success
	-- for a mode that is not running.
	if not active then
		return false
	end

	local interval = config().interval_ms
	timer = vim.loop.new_timer()
	timer:start(interval, interval, function()
		vim.schedule(function()
			if active then
				-- Re-seed if the baseline poll never landed, rather than treating
				-- an empty snapshot as "nothing has changed yet".
				tick(not seeded)
			end
		end)
	end)

	return true
end

---Stops the mode and releases everything it owns. Safe to call when inactive,
---since the toggle and VimLeavePre can both reach it.
---
---Accumulated state is cleared unconditionally, but the timer, the autocmds and
---`on_stop` are released only when the mode was actually running -- so a second
---stop cannot run the hook twice, and a stop after a start that never happened
---still leaves nothing behind.
function M.stop()
	local was_active = active
	active = false
	generation = generation + 1

	-- Before anything else: a subprocess outliving the mode is exactly the leak
	-- these guards exist to prevent.
	abandon_pending()
	abandon_draining()

	if timer then
		-- Both calls: a stopped-but-unclosed uv handle still leaks.
		pcall(function()
			timer:stop()
			timer:close()
		end)
		timer = nil
	end

	if write_augroup then
		pcall(vim.api.nvim_del_augroup_by_id, write_augroup)
		write_augroup = nil
	end

	local on_stop = was_active and started_opts and started_opts.on_stop or nil
	started_opts = nil
	workspace = nil
	seeded = false
	consecutive_failures = 0
	ring.clear()

	if on_stop then
		pcall(on_stop)
	end
end

---Resolves the configured source, defaulting to the git adapter.
---@param root string
---@return table
function M.resolve_source(root)
	local configured = config().source
	if type(configured) == "function" then
		return configured(root)
	end
	return monitor_source.git(root)
end

---Test seam: the ring instance, so specs can drive absorb/self-writes directly
---without a timer. Deliberately the *same* instance the tick path uses, so a
---spec cannot pass against a parallel copy.
---@return MonitorRing
function M._ring()
	return ring
end

---Test seam: render a batch as a real tick would.
---@param entries MonitorEntry[] oldest first
function M._render(entries)
	drain(entries or {})
end

return M
