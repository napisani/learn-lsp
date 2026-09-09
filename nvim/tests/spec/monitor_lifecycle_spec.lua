-- Monitor mode teardown: nothing may outlive the mode.
--
-- These exist because stopping once left things running: the poll timer kept
-- shelling out to git after the mode was dismissed, and a subprocess callback
-- from a previous run could tear down a later one.
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq

local monitor = require("vantage.monitor")
local monitor_source = require("vantage.monitor_source")
local state = require("vantage.state")

---Live, non-closing libuv timers. The suite asserts a delta rather than an
---absolute count, since Neovim owns timers of its own.
local function timers()
	local count = 0
	vim.loop.walk(function(handle)
		if vim.loop.handle_get_type(handle) == "timer" and not vim.loop.is_closing(handle) then
			count = count + 1
		end
	end)
	return count
end

---Whether the write-watching augroup exists at all.
---
---Deliberately checks for the *group*, not a count of autocmds: the next start
---recreates it with `clear = true`, so a leaked group is invisible to any
---before/after tally -- the baseline simply absorbs it.
local function write_group_exists()
	local ok, found = pcall(vim.api.nvim_get_autocmds, { group = "VantageMonitorWrites" })
	return ok and #found > 0
end

---A source that records how many times it was polled.
local function counting_source()
	local source = { polls = 0 }
	function source.poll(cb)
		source.polls = source.polls + 1
		cb({}, nil)
	end
	return source
end

local function reset()
	monitor.stop()
	helpers.fresh_buffer()
	state.setup({ monitor = { interval_ms = 20 } })
end

local function workspace_with_file()
	local root = helpers.temp_workspace()
	local path = root .. "/a.lua"
	helpers.writefile(path, "one\ntwo\n")
	return root, path
end

local function start(source, render)
	local root, path = workspace_with_file()
	monitor.start({
		workspace = root,
		source = source or monitor_source.fake({}),
		render = render or function() end,
	})
	return root, path
end

test("stop closes the poll timer rather than only stopping it", function()
	reset()
	local before = timers()

	start()
	assert(timers() > before, "expected start() to create a timer")
	monitor.stop()

	-- A stopped-but-unclosed uv handle still leaks.
	eq(timers(), before)
end)

test("the poll timer stops firing after stop", function()
	reset()
	local source = counting_source()
	start(source)
	vim.wait(80)
	assert(source.polls > 1, "expected the timer to have polled")

	monitor.stop()
	local after_stop = source.polls
	vim.wait(200)

	eq(source.polls, after_stop)
end)

test("repeated start and stop cycles leak no timers", function()
	reset()
	local before = timers()

	for _ = 1, 10 do
		start()
		monitor.stop()
	end

	eq(timers(), before)
end)

test("stop deletes the write-watching augroup", function()
	reset()
	start()
	eq(write_group_exists(), true)

	monitor.stop()

	eq(write_group_exists(), false)
end)

test("stop runs a configured on_stop exactly once", function()
	reset()
	local torn = 0
	local root = helpers.temp_workspace()
	monitor.start({
		workspace = root,
		source = monitor_source.fake({}),
		render = function() end,
		on_stop = function()
			torn = torn + 1
		end,
	})

	monitor.stop()
	monitor.stop()

	-- Only a custom renderer has anything to tear down, and it must not be
	-- torn down twice.
	eq(torn, 1)
end)

test("an in-flight poll landing after stop is ignored", function()
	reset()
	local deferred = nil
	local rendered = {}
	local root, path = workspace_with_file()
	monitor.start({
		workspace = root,
		source = { poll = function(cb) deferred = cb end },
		render = function(context)
			table.insert(rendered, context.path)
		end,
	})

	monitor.stop()
	-- The subprocess callback outlives the mode; it must not repopulate the ring
	-- or render anything after teardown.
	if deferred then
		deferred({ { path = path, status = " M" } }, nil)
	end

	eq(#monitor.entries(), 0)
	eq(#rendered, 0)
	eq(monitor.is_active(), false)
end)

test("a poll from a previous run cannot tear down a later one", function()
	reset()
	local deferred = nil
	local root = helpers.temp_workspace()
	monitor.start({
		workspace = root,
		source = { poll = function(cb) deferred = cb end },
		render = function() end,
	})
	monitor.stop()

	-- Restart before the first run's subprocess callback lands. Guarding only on
	-- `active` is not enough here: the mode *is* active again, just a different
	-- run, so a stale error would stop a run it knows nothing about.
	monitor.start({ workspace = root, source = counting_source(), render = function() end })

	if deferred then
		deferred(nil, "fatal: not a git repository")
	end

	eq(monitor.is_active(), true)
	monitor.stop()
end)

test("a stale poll's changes do not enter a later run's ring", function()
	reset()
	local deferred = nil
	local root, path = workspace_with_file()
	monitor.start({
		workspace = root,
		source = { poll = function(cb) deferred = cb end },
		render = function() end,
	})
	monitor.stop()
	monitor.start({ workspace = root, source = counting_source(), render = function() end })

	if deferred then
		deferred({ { path = path, status = " M" } }, nil)
	end

	eq(#monitor.entries(), 0)
	monitor.stop()
end)

test("a raising renderer stops the mode instead of firing every tick", function()
	reset()
	local root, path = workspace_with_file()
	monitor.start({
		workspace = root,
		source = monitor_source.fake({}),
		render = function()
			error("renderer blew up")
		end,
	})

	monitor._render({ { path = path, status = " M", mtime = 1, at = os.time() } })

	eq(monitor.is_active(), false)
end)

-- The in-flight guard. A poll slower than `interval_ms` used to stack: the timer
-- kept firing and each tick spawned another subprocess, without bound. Measured
-- at a 20ms interval against a source that never answered, 29 piled up in 600ms
-- -- each holding pipe file descriptors, which is enough of a leak to exhaust
-- the system file table and take the editor session down with it.

---A source that never answers, counting how many polls were issued.
local function silent_source()
	local source = { issued = 0, killed = 0 }
	function source.poll(_)
		source.issued = source.issued + 1
		return {
			kill = function()
				source.killed = source.killed + 1
			end,
		}
	end
	return source
end

test("a poll already in flight suppresses the next tick", function()
	reset()
	local source = silent_source()
	monitor.start({ workspace = helpers.temp_workspace(), source = source, render = function() end })

	-- Many intervals elapse, and the first poll never answers.
	vim.wait(300)

	-- Exactly one, not one per tick.
	eq(source.issued, 1)
	eq(monitor.health().polling, true)
	monitor.stop()
end)

test("the guard releases once a poll answers", function()
	reset()
	local answer = nil
	local issued = 0
	monitor.start({
		workspace = helpers.temp_workspace(),
		source = {
			poll = function(cb)
				issued = issued + 1
				answer = cb
			end,
		},
		render = function() end,
	})
	vim.wait(120)
	eq(issued, 1)

	answer({}, nil)
	eq(monitor.health().polling, false)
	vim.wait(120)

	-- Ticks resume now that nothing is outstanding.
	assert(issued > 1, "expected polling to resume, saw " .. issued)
	monitor.stop()
end)

test("an unanswered poll is abandoned and killed after poll_timeout_ms", function()
	reset()
	state.setup({ monitor = { interval_ms = 20, poll_timeout_ms = 60 } })
	local source = silent_source()
	monitor.start({ workspace = helpers.temp_workspace(), source = source, render = function() end })

	vim.wait(400)

	-- A poll that will never answer must not wedge the mode forever, and the
	-- subprocess behind it must actually die rather than hold its pipes open.
	assert(source.issued > 1, "expected the stuck poll to be abandoned, issued=" .. source.issued)
	assert(source.killed > 0, "expected the abandoned poll to be killed")
	monitor.stop()
end)

test("stop kills a poll still in flight", function()
	reset()
	local source = silent_source()
	monitor.start({ workspace = helpers.temp_workspace(), source = source, render = function() end })
	vim.wait(60)
	eq(monitor.health().polling, true)

	monitor.stop()

	-- A subprocess outliving the mode is the leak this exists to prevent.
	eq(source.killed, 1)
	eq(monitor.health().polling, false)
end)

test("a late answer from an abandoned poll is ignored", function()
	reset()
	state.setup({ monitor = { interval_ms = 20, poll_timeout_ms = 40 } })
	local root = helpers.temp_workspace()
	local path = root .. "/a.lua"
	helpers.writefile(path, "one\n")

	-- The seeding poll must answer normally: it emits nothing by design, so
	-- withholding *it* could never reveal a missing guard.
	local polls, withheld, rendered = 0, nil, 0
	monitor.start({
		workspace = root,
		source = {
			poll = function(cb)
				polls = polls + 1
				if polls == 2 then
					withheld = cb
				else
					cb({}, nil)
				end
				return { kill = function() end }
			end,
		},
		render = function()
			rendered = rendered + 1
		end,
	})

	vim.wait(400)
	assert(withheld ~= nil, "expected a second poll to be withheld")
	assert(polls > 2, "expected the withheld poll to be abandoned, polls=" .. polls)

	-- It answers late, reporting a real change. A live poll's answer would
	-- render; an abandoned one's must not.
	withheld({ { path = path, status = " M" } }, nil)

	eq(rendered, 0)
	monitor.stop()
end)

test("a source that raises does not wedge the guard", function()
	reset()
	monitor.start({
		workspace = helpers.temp_workspace(),
		source = {
			poll = function()
				error("source blew up")
			end,
		},
		render = function() end,
	})

	-- Leaving `pending` set here would block every future tick, and the mode
	-- would go silently quiet rather than reporting a problem.
	eq(monitor.health().polling, false)
	eq(monitor.is_active(), false)
end)

-- --- Drain guarding, retry policy, seeding, and the config->seam wiring ---

test("a drain in flight suppresses the next poll", function()
	reset()
	state.setup({ monitor = { interval_ms = 20 } })
	local root = helpers.temp_workspace()
	local path = root .. "/a.lua"
	helpers.writefile(path, "one\n")

	local polls = 0
	local hold_hunk = nil
	monitor.start({
		workspace = root,
		source = {
			poll = function(cb)
				polls = polls + 1
				-- Nothing on the seeding poll: a change present at seed time is
				-- baseline, so it would never be emitted.
				cb(polls == 1 and {} or { { path = path, status = " M" } }, nil)
			end,
			first_hunk = function(_, cb)
				hold_hunk = cb
				return { kill = function() end }
			end,
		},
		render = function() end,
	})

	vim.wait(300)

	-- The poll guard alone was not enough: `pending` is cleared before draining,
	-- so a second concurrent drain could interleave renders and scramble the
	-- jumplist trail the sequential drain exists to protect.
	eq(monitor.health().draining, true)
	assert(polls <= 2, "expected polling to pause while draining, saw " .. polls)
	monitor.stop()
end)

test("stop kills a hunk lookup a drain is waiting on", function()
	reset()
	local root = helpers.temp_workspace()
	local path = root .. "/a.lua"
	helpers.writefile(path, "one\n")
	local killed = 0

	monitor.start({
		workspace = root,
		source = {
			poll = function(cb) cb({}, nil) end,
			first_hunk = function(_, _)
				return { kill = function() killed = killed + 1 end }
			end,
		},
		render = function() end,
	})
	monitor._render({ { path = path, status = " M", mtime = 1, at = os.time() } })
	eq(monitor.health().draining, true)

	monitor.stop()

	-- A `git diff` outliving the mode is the same leak class the poll guard fixed.
	eq(killed, 1)
end)

test("a transient poll failure retries instead of stopping the mode", function()
	reset()
	state.setup({ monitor = { interval_ms = 20 } })
	local failures = 0
	monitor.start({
		workspace = helpers.temp_workspace(),
		source = {
			poll = function(cb)
				failures = failures + 1
				cb(nil, "fatal: Unable to create index.lock: File exists")
			end,
		},
		render = function() end,
	})

	vim.wait(80)

	-- index.lock contention is exactly what an adjacent agent causes; one such
	-- failure used to kill the mode permanently after a single warning.
	assert(failures >= 2, "expected a retry, saw " .. failures .. " poll(s)")
	monitor.stop()
end)

test("repeated poll failures eventually stop the mode", function()
	reset()
	state.setup({ monitor = { interval_ms = 10 } })
	monitor.start({
		workspace = helpers.temp_workspace(),
		source = { poll = function(cb) cb(nil, "fatal: not a git repository") end },
		render = function() end,
	})

	vim.wait(400, function()
		return not monitor.is_active()
	end, 10)

	eq(monitor.is_active(), false)
end)

test("start reports failure when the seeding tick stops the mode", function()
	reset()
	local started = monitor.start({
		workspace = helpers.temp_workspace(),
		source = {
			poll = function()
				error("source blew up")
			end,
		},
		render = function() end,
	})

	-- Reporting success for a dead mode also orphaned the timer created after
	-- the seeding tick, which no later stop() could reach.
	eq(started, false)
	eq(monitor.is_active(), false)
	eq(monitor.health().polling, false)
end)

test("an abandoned seeding poll is retried rather than skipped", function()
	reset()
	state.setup({ monitor = { interval_ms = 20, poll_timeout_ms = 40 } })
	local seeds = {}
	monitor.start({
		workspace = helpers.temp_workspace(),
		source = {
			poll = function(_)
				-- Never answers; the first is abandoned on timeout.
				table.insert(seeds, true)
				return { kill = function() end }
			end,
		},
		render = function() end,
	})

	vim.wait(300)

	-- Without re-seeding, the empty baseline would make the next successful poll
	-- emit the entire dirty worktree.
	eq(monitor.health().seeded, false)
	assert(#seeds > 1, "expected the abandoned seed to be retried")
	monitor.stop()
end)

test("a repeated warning is announced again after the cooldown", function()
	reset()
	state.setup({ monitor = { interval_ms = 10, warn_cooldown_ms = 0 } })
	-- Count repeats of ONE key. Counting all notices would pass regardless, since
	-- the retry and the give-up warning use different keys.
	local retries = 0
	local real_notify = vim.notify
	vim.notify = function(message)
		if type(message) == "string" and message:match("retrying") then
			retries = retries + 1
		end
	end
	monitor.start({
		workspace = helpers.temp_workspace(),
		source = { poll = function(cb) cb(nil, "transient") end },
		render = function() end,
	})
	vim.wait(200)
	vim.notify = real_notify

	-- warn_once suppressed forever, so recurring degradation went silent after
	-- the first notification.
	assert(retries > 1, "expected the same warning to re-arm, saw " .. retries)
	monitor.stop()
end)

test("health reports enough to tell a quiet repo from a failing mode", function()
	reset()
	local health = monitor.health()

	eq(health.active, false)
	eq(health.seeded, false)
	eq(health.consecutive_failures, 0)
	eq(health.entries, 0)
end)

test("commands.monitor wires configured source, render and on_stop through", function()
	reset()
	local root = helpers.temp_workspace()
	vim.cmd("cd " .. root)
	local seen = { source = false, render = false, stopped = false }

	state.setup({
		monitor = {
			interval_ms = 20,
			source = function()
				seen.source = true
				local polls = 0
				return {
					poll = function(cb)
						polls = polls + 1
						-- Empty on the seeding poll; the change lands after.
						cb(polls == 1 and {} or { { path = root .. "/a.lua", status = " M" } }, nil)
					end,
				}
			end,
			render = function()
				seen.render = true
			end,
			on_stop = function()
				seen.stopped = true
			end,
		},
	})
	helpers.writefile(root .. "/a.lua", "one\n")

	require("vantage.commands").monitor()
	vim.wait(200, function()
		return seen.render
	end, 10)
	require("vantage.commands").monitor()

	-- These three seams are the documented reason a diff view stays
	-- config-supplied, and nothing previously proved a configured one arrived.
	eq(seen.source, true)
	eq(seen.render, true)
	eq(seen.stopped, true)
end)
