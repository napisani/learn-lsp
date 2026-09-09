-- Monitor mode's default presentation: open the changed file natively.
--
-- The whole point of this renderer is that it binds nothing. Opening a file is
-- already a Vim jump, so the assertions here are about the *jumplist* -- that
-- <C-o> and <C-i> walk recent edits because Neovim recorded the navigation, not
-- because Vantage wired up keys.
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq

local monitor = require("vantage.monitor")
local monitor_source = require("vantage.monitor_source")
local navigate = require("vantage.ui.navigate")
local state = require("vantage.state")

local function reset()
	monitor.stop()
	helpers.fresh_buffer()
	state.setup({})
end

---Feeds a real key through, so the jumplist is exercised the way a user does.
---`<C-i>` is literally Tab, which `:normal!` swallows as a blank argument.
local function key(lhs)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), "nx", false)
end

---Resolved current path plus cursor line. Resolved because macOS reports the
---same temp directory as both /var/... and /private/var/....
local function here()
	return helpers.normalized_path(vim.api.nvim_buf_get_name(0)), vim.api.nvim_win_get_cursor(0)[1]
end

local function same(actual, expected)
	eq(actual, helpers.normalized_path(expected))
end

local function workspace(files)
	local root = helpers.temp_workspace()
	local paths = {}
	for name, lines in pairs(files or { ["a.lua"] = { "one", "two", "three" } }) do
		local path = root .. "/" .. name
		helpers.writefile(path, table.concat(lines, "\n") .. "\n")
		paths[name] = path
	end
	return root, paths
end

local function context(path, opts)
	opts = opts or {}
	return {
		path = path,
		status = opts.status or " M",
		workspace = opts.workspace or vim.fn.fnamemodify(path, ":h"),
		line = opts.line,
		deleted = opts.deleted == true,
	}
end

test("navigate opens the changed file in the current window", function()
	reset()
	local _, paths = workspace()

	eq(navigate.open(context(paths["a.lua"])), true)

	local name = here()
	same(name, paths["a.lua"])
end)

test("navigate places the cursor on the changed line", function()
	reset()
	local _, paths = workspace()

	navigate.open(context(paths["a.lua"], { line = 3 }))

	local _, line = here()
	eq(line, 3)
end)

test("navigate clamps a line past the end of the file", function()
	reset()
	local _, paths = workspace()

	navigate.open(context(paths["a.lua"], { line = 9999 }))

	local _, line = here()
	eq(line, 3)
end)

test("navigate records a jump so <C-o> returns to where you were", function()
	reset()
	local _, paths = workspace({
		["a.lua"] = { "a1", "a2", "a3" },
		["b.lua"] = { "b1", "b2", "b3" },
	})

	vim.cmd("edit " .. vim.fn.fnameescape(paths["a.lua"]))
	vim.api.nvim_win_set_cursor(0, { 3, 0 })

	navigate.open(context(paths["b.lua"], { line = 2 }))
	local name, line = here()
	same(name, paths["b.lua"])
	eq(line, 2)

	key("<C-o>")

	-- Nothing bound this: `:edit` is a jump, so the jumplist did the work.
	local back_name, back_line = here()
	same(back_name, paths["a.lua"])
	eq(back_line, 3)
end)

test("navigate builds a trail <C-o> and <C-i> can walk both ways", function()
	reset()
	local _, paths = workspace({
		["a.lua"] = { "a1", "a2", "a3" },
		["b.lua"] = { "b1", "b2", "b3" },
		["c.lua"] = { "c1", "c2", "c3" },
	})

	vim.cmd("edit " .. vim.fn.fnameescape(paths["a.lua"]))
	vim.api.nvim_win_set_cursor(0, { 2, 0 })
	navigate.open(context(paths["b.lua"]))
	navigate.open(context(paths["c.lua"]))

	key("<C-o>")
	same((here()), paths["b.lua"])
	key("<C-o>")
	same((here()), paths["a.lua"])
	key("<C-i>")
	same((here()), paths["b.lua"])
end)

test("navigate binds no keymaps of its own", function()
	reset()
	local _, paths = workspace()

	navigate.open(context(paths["a.lua"]))
	local buf = vim.api.nvim_get_current_buf()

	-- The previous design bound <Up>/<Down>/q on the displayed buffer, which
	-- shadowed arrow-key movement in a real file. Nothing may be bound now.
	for _, mode in ipairs({ "n", "i" }) do
		eq(#vim.api.nvim_buf_get_keymap(buf, mode), 0)
	end
end)

test("navigate leaves buffer options untouched", function()
	reset()
	local _, paths = workspace()

	navigate.open(context(paths["a.lua"]))
	local buf = vim.api.nvim_get_current_buf()

	eq(vim.bo[buf].modifiable, true)
	eq(vim.bo[buf].readonly, false)
	eq(vim.bo[buf].buftype, "")
end)

test("navigate does not open a deleted path", function()
	reset()
	local root = helpers.temp_workspace()
	vim.cmd("enew!")
	local before = vim.api.nvim_get_current_buf()

	local navigated = navigate.open(context(root .. "/gone.lua", { deleted = true, status = " D" }))

	-- `:edit` on a missing path would make an empty buffer indistinguishable
	-- from a file whose contents were cleared.
	eq(navigated, false)
	eq(vim.api.nvim_get_current_buf(), before)
end)

test("navigate refuses to reload the current buffer when it has unsaved work", function()
	reset()
	local _, paths = workspace()
	vim.cmd("edit " .. vim.fn.fnameescape(paths["a.lua"]))
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { "my unsaved edit" })

	helpers.writefile(paths["a.lua"], "agent wrote this\n")
	local navigated = navigate.open(context(paths["a.lua"]))

	eq(navigated, false)
	eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "my unsaved edit" })
	vim.bo.modified = false
end)

test("navigate reloads the current buffer when it is clean", function()
	reset()
	local _, paths = workspace()
	vim.cmd("edit " .. vim.fn.fnameescape(paths["a.lua"]))

	helpers.writefile(paths["a.lua"], "agent wrote this\n")
	eq(navigate.open(context(paths["a.lua"])), true)

	eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "agent wrote this" })
end)

test("navigate does nothing while the user is not in normal mode", function()
	reset()
	local _, paths = workspace()
	vim.cmd("enew!")
	local before = vim.api.nvim_get_current_buf()

	-- Swapping the buffer out from under someone who is typing would send their
	-- next keystrokes into the file the agent is editing.
	local real_mode = vim.fn.mode
	vim.fn.mode = function()
		return "i"
	end
	local navigated = navigate.open(context(paths["a.lua"]))
	vim.fn.mode = real_mode

	eq(navigated, false)
	eq(vim.api.nvim_get_current_buf(), before)
end)

test("monitor renders every change in a burst, oldest first", function()
	reset()
	local root, paths = workspace({
		["a.lua"] = { "a1" },
		["b.lua"] = { "b1" },
	})
	local seen = {}
	monitor.start({
		workspace = root,
		source = monitor_source.fake({}),
		render = function(ctx)
			table.insert(seen, ctx.path)
		end,
	})

	monitor._render({
		{ path = paths["a.lua"], status = " M", mtime = 1, at = os.time() },
		{ path = paths["b.lua"], status = " M", mtime = 1, at = os.time() },
	})

	-- Every entry renders, in order: that is what lays down a jumplist trail
	-- rather than a single hop to whichever file happened to be last.
	eq(seen, { paths["a.lua"], paths["b.lua"] })
	monitor.stop()
end)

test("monitor hands the renderer a context table with the workspace root", function()
	reset()
	local root, paths = workspace()
	local captured = nil
	monitor.start({
		workspace = root,
		source = monitor_source.fake({}),
		render = function(ctx)
			captured = ctx
		end,
	})

	monitor._render({ { path = paths["a.lua"], status = " M", mtime = 1, at = os.time() } })

	-- A single extensible table, so a diff-view renderer can be given more
	-- without breaking renderers that already exist.
	eq(captured.path, paths["a.lua"])
	eq(captured.status, " M")
	eq(captured.workspace, root)
	eq(captured.deleted, false)
	monitor.stop()
end)

test("monitor marks a deleted path in the render context", function()
	reset()
	local root = helpers.temp_workspace()
	local captured = nil
	monitor.start({
		workspace = root,
		source = monitor_source.fake({}),
		render = function(ctx)
			captured = ctx
		end,
	})

	monitor._render({ { path = root .. "/gone.lua", status = " D", mtime = 0, at = os.time() } })

	eq(captured.deleted, true)
	eq(captured.line, nil)
	monitor.stop()
end)

test("monitor uses the source's first_hunk to fill in the line", function()
	reset()
	local root, paths = workspace()
	local source = monitor_source.fake({})
	function source.first_hunk(_, cb)
		cb(2)
	end

	local captured = nil
	monitor.start({
		workspace = root,
		source = source,
		render = function(ctx)
			captured = ctx
		end,
	})
	monitor._render({ { path = paths["a.lua"], status = " M", mtime = 1, at = os.time() } })

	eq(captured.line, 2)
	monitor.stop()
end)

test("monitor still renders when a source offers no first_hunk", function()
	reset()
	local root, paths = workspace()
	local captured = nil
	monitor.start({
		workspace = root,
		source = { poll = function(cb) cb({}, nil) end },
		render = function(ctx)
			captured = ctx
		end,
	})

	monitor._render({ { path = paths["a.lua"], status = " M", mtime = 1, at = os.time() } })

	-- Hunk position is an enhancement, never a precondition.
	eq(captured.path, paths["a.lua"])
	eq(captured.line, nil)
	monitor.stop()
end)
