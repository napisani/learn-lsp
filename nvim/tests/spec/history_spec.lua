-- the prompt-history ring: recording, dedup, cap, and cycle arithmetic
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq
local capture_notifications = helpers.capture_notifications

local history = require("vantage.history")
local history_store = require("vantage.history_store")

---Fresh ring backed by a fake store, so nothing touches the real state dir.
---@return table store the fake store, for asserting what was persisted
local function reset_history(config)
	local vantage = require("vantage")
	vantage.setup(vim.tbl_deep_extend("force", { backend = { mode = "development" } }, config or {}))
	local store = history_store.fake()
	history._set_store(store)
	return store
end

local function entry(text, overrides)
	return vim.tbl_extend("force", {
		kind = "question",
		text = text,
		workspaceRoot = "/w",
		submitted = true,
	}, overrides or {})
end

test("history.record stores an entry retrievable via entries()", function()
	reset_history()

	eq(history.record(entry("first")), true)

	local entries = history.entries()
	eq(#entries, 1)
	eq(entries[1].text, "first")
end)

test("history.entries returns newest first", function()
	reset_history()
	history.record(entry("older"))
	history.record(entry("newer"))

	local entries = history.entries()
	eq(entries[1].text, "newer")
	eq(entries[2].text, "older")
end)

test("history collapses duplicates and hoists the repeat to newest", function()
	reset_history()
	history.record(entry("repeated"))
	history.record(entry("other"))
	history.record(entry("repeated"))

	local entries = history.entries()
	eq(#entries, 2)
	eq(entries[1].text, "repeated")
	eq(entries[2].text, "other")
end)

test("a real send supersedes an abandoned draft of the same text", function()
	reset_history()
	history.record(entry("draft then sent", { submitted = false }))
	history.record(entry("draft then sent", { submitted = true }))

	local entries = history.entries()
	eq(#entries, 1)
	eq(entries[1].submitted, true)
end)

test("the same text in a different workspace is a separate entry", function()
	reset_history()
	history.record(entry("same text", { workspaceRoot = "/a" }))
	history.record(entry("same text", { workspaceRoot = "/b" }))

	eq(#history.entries(), 2)
end)

test("history drops the oldest entry past the configured limit", function()
	reset_history({ history = { limit = 3 } })
	for index = 1, 4 do
		history.record(entry("entry " .. index))
	end

	local entries = history.entries()
	eq(#entries, 3)
	eq(entries[1].text, "entry 4")
	eq(entries[#entries].text, "entry 2")
end)

test("history skips an entry over max_entry_bytes rather than truncating it", function()
	reset_history({ history = { max_entry_bytes = 32 } })

	local notifications = capture_notifications(function()
		eq(history.record(entry(string.rep("x", 64))), false)
	end)

	eq(#history.entries(), 0)
	assert(notifications[1] and notifications[1]:match("was not recorded"), vim.inspect(notifications))
end)

test("history.entries filters to one workspace when asked", function()
	reset_history()
	history.record(entry("here", { workspaceRoot = "/here" }))
	history.record(entry("there", { workspaceRoot = "/there" }))

	local scoped = history.entries({ workspace = "/here" })
	eq(#scoped, 1)
	eq(scoped[1].text, "here")
end)

test("history.record is a no-op when history is disabled", function()
	reset_history({ history = { enabled = false } })

	eq(history.record(entry("ignored")), false)
	eq(#history.entries(), 0)
end)

test("history.record ignores blank text", function()
	reset_history()

	eq(history.record(entry("")), false)
	eq(history.record(entry("   \n  ")), false)
	eq(#history.entries(), 0)
end)

test("cycling older from newest holds the current buffer as the draft", function()
	reset_history()
	history.record(entry("recorded"))

	local result = history.cycle("older", {}, { workspace = "/w", current = "typed so far" })

	eq(result.text, "recorded")
	eq(result.state.index, 1)
	eq(result.state.draft, "typed so far")
end)

test("cycling older stops at the oldest entry instead of wrapping", function()
	reset_history()
	history.record(entry("older"))
	history.record(entry("newer"))

	local first = history.cycle("older", {}, { workspace = "/w", current = "draft" })
	local second = history.cycle("older", first.state, { workspace = "/w", current = "draft" })
	local third = history.cycle("older", second.state, { workspace = "/w", current = "draft" })

	eq(second.text, "older")
	eq(third.text, nil)
	eq(third.state.index, 2)
end)

test("cycling newer past the newest entry restores the draft", function()
	reset_history()
	history.record(entry("recorded"))

	local older = history.cycle("older", {}, { workspace = "/w", current = "my draft" })
	local back = history.cycle("newer", older.state, { workspace = "/w", current = "recorded" })

	eq(back.text, "my draft")
	eq(back.state.index, nil)
	eq(back.state.draft, nil)
end)

test("cycling an empty pool leaves the state untouched", function()
	reset_history()

	local result = history.cycle("older", {}, { workspace = "/w", current = "draft" })

	eq(result.text, nil)
	eq(result.state.index, nil)
end)

test("cycling ignores entries from other workspaces", function()
	reset_history()
	history.record(entry("elsewhere", { workspaceRoot = "/other" }))
	history.record(entry("here", { workspaceRoot = "/w" }))

	local first = history.cycle("older", {}, { workspace = "/w", current = "draft" })
	local second = history.cycle("older", first.state, { workspace = "/w", current = "draft" })

	eq(first.text, "here")
	eq(second.text, nil)
end)

test("history.clear scoped to a workspace leaves other workspaces intact", function()
	reset_history()
	history.record(entry("mine", { workspaceRoot = "/mine" }))
	history.record(entry("theirs", { workspaceRoot = "/theirs" }))

	eq(history.clear({ workspace = "/mine" }), 1)

	local remaining = history.entries()
	eq(#remaining, 1)
	eq(remaining[1].text, "theirs")
end)

test("history.clear with no workspace empties everything", function()
	reset_history()
	history.record(entry("a"))
	history.record(entry("b", { workspaceRoot = "/elsewhere" }))

	eq(history.clear(), 2)
	eq(#history.entries(), 0)
end)

test("history.record persists through the store", function()
	local store = reset_history()
	history.record(entry("persisted"))

	local lines = store._lines()
	eq(#lines, 1)
	eq(lines[1].text, "persisted")
	eq(lines[1].submitted, true)
end)

test("history loads existing entries from the store on first use", function()
	local vantage = require("vantage")
	vantage.setup({ backend = { mode = "development" } })
	history._set_store(history_store.fake({
		{ kind = "question", text = "from disk", workspaceRoot = "/w", submitted = true, timestamp = 1 },
	}))

	local entries = history.entries()
	eq(#entries, 1)
	eq(entries[1].text, "from disk")
end)

test("a failing store append still leaves the entry cyclable this session", function()
	reset_history()
	local store = history_store.fake()
	store.append = function()
		return false, "ENOSPC"
	end
	history._set_store(store)

	local notifications = capture_notifications(function()
		eq(history.record(entry("unwritable")), true)
	end)

	eq(history.entries()[1].text, "unwritable")
	assert(notifications[1] and notifications[1]:match("could not write"), vim.inspect(notifications))
end)

-- ---------------------------------------------------------------------------
-- Record hooks and cycling, exercised through the real surfaces.
-- ---------------------------------------------------------------------------

local submit_prompt_buffer = helpers.submit_prompt_buffer
local lua_buffer = helpers.lua_buffer
local temp_workspace = helpers.temp_workspace
local set_buffer_path = helpers.set_buffer_path
local prompt_buffer_mapped = helpers.prompt_buffer_mapped
local capture_backend_request = helpers.capture_backend_request

---A workspace-scoped fixture: a real file in a real git root, so params carry a
---workspaceRoot that cycling can filter on.
local function in_workspace(config)
	local store = reset_history(config)
	local root = temp_workspace()
	lua_buffer({ "local a = 1" })
	set_buffer_path(root .. "/mod.lua")
	return store, root
end

local function float_buf()
	return require("vantage.ui").last_float_buf()
end

test("submitting the prompt float records the raw text, not the expanded text", function()
	local vantage = require("vantage")
	in_workspace()

	vantage.prompt({ params = require("vantage.context").scoped({}), on_submit = function() end })
	submit_prompt_buffer("look at @mod.lua")

	local entries = history.entries()
	eq(#entries, 1)
	-- The submitted text is expanded with a references block; history must not be.
	eq(entries[1].text, "look at @mod.lua")
	assert(not entries[1].text:match("Vantage Prompt References"), entries[1].text)
end)

test("cancelling a non-empty prompt float records an unsent draft", function()
    local vantage = require("vantage")
	in_workspace()

	vantage.prompt({ on_submit = function() end })
	local buf = float_buf()
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abandoned text" })
	vim.api.nvim_set_current_win(require("vantage.ui").last_float_win())
	vim.api.nvim_feedkeys("q", "x", false)

	local entries = history.entries()
	eq(#entries, 1)
	eq(entries[1].text, "abandoned text")
	eq(entries[1].submitted, false)
end)

test("cancelling an empty prompt float records nothing", function()
	local vantage = require("vantage")
	in_workspace()

	vantage.prompt({ on_submit = function() end })
	vim.api.nvim_set_current_win(require("vantage.ui").last_float_win())
	vim.api.nvim_feedkeys("q", "x", false)

	eq(#history.entries(), 0)
end)

test("the inline-args command path records without opening a buffer", function()
	in_workspace()

	capture_backend_request({
		ok = true,
		result = { kind = "explanation", markdown = "answer" },
	}, function()
		vim.cmd("VantageQuestion why is this slow")
	end)

	local entries = history.entries()
	eq(#entries, 1)
	eq(entries[1].text, "why is this slow")
	eq(entries[1].kind, "question")
end)

test("composition send records the staged text as a composition entry", function()
	local vantage = require("vantage")
	in_workspace({ composition = { on_send = function() return true end } })

	vantage.compose_append("staged work")
	vantage.compose_send()

	local entries = history.entries()
	eq(#entries, 1)
	eq(entries[1].kind, "composition")
	eq(entries[1].text, "staged work")
end)

test("closing the composition window records nothing", function()
	local vantage = require("vantage")
	in_workspace()

	vantage.compose_append("still here")
	local before = #history.entries()
	require("vantage.composition").close()

	-- Composition close only hides the window; the content survives, so there is
	-- nothing to rescue and nothing to record.
	eq(#history.entries(), before)
end)

test("a raising history.record does not prevent the submit", function()
	local vantage = require("vantage")
	in_workspace()
	local original = history.record
	history.record = function()
		error("history is broken")
	end

	local submitted
	vantage.prompt({ on_submit = function(text) submitted = text end })
	submit_prompt_buffer("still goes through")

	history.record = original
	eq(submitted, "still goes through")
end)

test("prompt float binds the cycle keys, an ordinary buffer does not", function()
	local vantage = require("vantage")
	in_workspace()
	local ordinary = vim.api.nvim_get_current_buf()

	vantage.prompt({ on_submit = function() end })

	eq(prompt_buffer_mapped(float_buf(), "n", "<Up>"), true)
	eq(prompt_buffer_mapped(float_buf(), "i", "<Down>"), true)
	eq(prompt_buffer_mapped(ordinary, "n", "<Up>"), false)
end)

test("history.enabled = false unbinds the cycle keys with the keymaps left at their defaults", function()
	local vantage = require("vantage")
	-- Deliberately does NOT blank history_prev/history_next: the point is that
	-- `enabled` alone is a working kill switch. Setting both made the previous
	-- version of this test pass whether or not `enabled` did anything.
	in_workspace({ history = { enabled = false } })

	vantage.prompt({ on_submit = function() end })

	eq(prompt_buffer_mapped(float_buf(), "n", "<Up>"), false)
	eq(prompt_buffer_mapped(float_buf(), "i", "<Down>"), false)
end)

test("history.enabled = false leaves previously recorded entries unreachable by cycling", function()
	local vantage = require("vantage")
	in_workspace()
	local params = require("vantage.context").scoped({})
	history.record({ kind = "question", text = "recorded while on", workspaceRoot = params.workspaceRoot })

	vantage.setup({ backend = { mode = "development" }, history = { enabled = false } })
	vantage.prompt({ params = params, on_submit = function() end })
	local buf = float_buf()
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "untouched" })
	vim.api.nvim_set_current_win(require("vantage.ui").last_float_win())
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Up>", true, false, true), "x", false)

	eq(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), "untouched")
	vim.api.nvim_win_close(require("vantage.ui").last_float_win(), true)
end)

test("<Up> in the prompt float recalls the newest entry and <Down> restores the draft", function()
	local vantage = require("vantage")
	local _, root = in_workspace()
	local params = require("vantage.context").scoped({})
	history.record({ kind = "question", text = "previous prompt", workspaceRoot = params.workspaceRoot })

	vantage.prompt({ params = params, on_submit = function() end })
	local buf = float_buf()
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "my draft" })
	vim.api.nvim_set_current_win(require("vantage.ui").last_float_win())

	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Up>", true, false, true), "x", false)
	eq(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), "previous prompt")

	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Down>", true, false, true), "x", false)
	eq(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), "my draft")

	vim.api.nvim_win_close(require("vantage.ui").last_float_win(), true)
end)

test("editing a recalled entry then cycling again discards the edit", function()
	local vantage = require("vantage")
	in_workspace()
	local params = require("vantage.context").scoped({})
	history.record({ kind = "question", text = "older", workspaceRoot = params.workspaceRoot })
	history.record({ kind = "question", text = "newer", workspaceRoot = params.workspaceRoot })

	vantage.prompt({ params = params, on_submit = function() end })
	local buf = float_buf()
	vim.api.nvim_set_current_win(require("vantage.ui").last_float_win())

	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Up>", true, false, true), "x", false)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "newer, edited" })
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Up>", true, false, true), "x", false)

	-- Shell semantics: only the pre-cycle draft is held, so the edit is gone.
	eq(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), "older")

	vim.api.nvim_win_close(require("vantage.ui").last_float_win(), true)
end)

test("cycling in the composition buffer replaces it and <Down> restores the staged work", function()
	local vantage = require("vantage")
	in_workspace()
	vantage.compose_append("staged work")
	local params = require("vantage.context").scoped({})
	history.record({ kind = "question", text = "recalled", workspaceRoot = params.workspaceRoot })

	vantage.compose()
	local buf = require("vantage.composition").get_bufnr()
	local win = require("vantage.ui.window").window_in_current_tabpage(buf)
	vim.api.nvim_set_current_win(win)

	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Up>", true, false, true), "x", false)
	eq(require("vantage.composition").content(), "recalled")

	-- The staged work is only recoverable because the draft is held.
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Down>", true, false, true), "x", false)
	eq(require("vantage.composition").content(), "staged work")
end)

test("VantageHistoryClearWorkspace removes only this workspace's entries", function()
	local _, root = in_workspace()
	local params = require("vantage.context").scoped({})
	history.record({ kind = "question", text = "mine", workspaceRoot = params.workspaceRoot })
	history.record({ kind = "question", text = "elsewhere", workspaceRoot = "/somewhere/else" })

	vim.cmd("VantageHistoryClearWorkspace")

	local remaining = history.entries()
	eq(#remaining, 1)
	eq(remaining[1].text, "elsewhere")
end)

test("VantageHistoryClearAll empties history across workspaces", function()
	in_workspace()
	history.record(entry("a", { workspaceRoot = "/one" }))
	history.record(entry("b", { workspaceRoot = "/two" }))

	vim.cmd("VantageHistoryClearAll")

	eq(#history.entries(), 0)
end)

test("VantageHistory writes the chosen entry into a focused prompt buffer", function()
	local vantage = require("vantage")
	in_workspace()
	local params = require("vantage.context").scoped({})
	history.record({ kind = "question", text = "recalled via picker", workspaceRoot = params.workspaceRoot })

	vantage.prompt({ params = params, on_submit = function() end })
	local buf = float_buf()
	vim.api.nvim_set_current_win(require("vantage.ui").last_float_win())

	local original = vim.ui.select
	vim.ui.select = function(items, _, on_choice)
		on_choice(items[1], 1)
	end
	vim.cmd("VantageHistory")
	vim.ui.select = original

	eq(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), "recalled via picker")
	vim.api.nvim_win_close(require("vantage.ui").last_float_win(), true)
end)

test("VantageHistory from an ordinary buffer yanks instead of editing it", function()
	in_workspace()
	local params = require("vantage.context").scoped({})
	history.record({ kind = "question", text = "yanked entry", workspaceRoot = params.workspaceRoot })
	local buf = vim.api.nvim_get_current_buf()
	local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	vim.fn.setreg("", "")

	local original = vim.ui.select
	vim.ui.select = function(items, _, on_choice)
		on_choice(items[1], 1)
	end
	vim.cmd("VantageHistory")
	vim.ui.select = original

	eq(vim.fn.getreg(""), "yanked entry")
	eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before)
end)

test("VantageHistory marks abandoned drafts distinctly from submitted prompts", function()
	in_workspace()
	local params = require("vantage.context").scoped({})
	history.record({ kind = "question", text = "abandoned", workspaceRoot = params.workspaceRoot, submitted = false })

	local shown
	local original = vim.ui.select
	vim.ui.select = function(items, _, on_choice)
		shown = items
		on_choice(nil, nil)
	end
	vim.cmd("VantageHistory")
	vim.ui.select = original

	assert(shown and shown[1]:match("^~"), "expected an unsent marker, got: " .. vim.inspect(shown))
end)

-- ---------------------------------------------------------------------------
-- Regressions from the multi-valued review.
-- ---------------------------------------------------------------------------

test("clearing one workspace preserves on-disk entries beyond this session's cap", function()
	local vantage = require("vantage")
	vantage.setup({ backend = { mode = "development" }, history = { limit = 5 } })
	local seed = {}
	for index = 1, 6 do
		table.insert(seed, { text = "a" .. index, workspaceRoot = "/wsA", kind = "question", submitted = true })
	end
	for index = 1, 6 do
		table.insert(seed, { text = "b" .. index, workspaceRoot = "/wsB", kind = "question", submitted = true })
	end
	local store = history_store.fake(seed)
	history._set_store(store)

	history.clear({ workspace = "/wsA" })

	-- The ring only ever held 5 of the 12; clearing must not destroy the /wsB
	-- entries that fell off the cap.
	local survivors = 0
	for _, row in ipairs(store._lines()) do
		assert(row.workspaceRoot ~= "/wsA", "expected /wsA to be gone, saw " .. row.text)
		survivors = survivors + 1
	end
	eq(survivors, 6)
end)

test("clear reports failure instead of a success count when the rewrite fails", function()
	reset_history()
	history.record(entry("staged"))
	local store = history_store.fake()
	store.load = function()
		return { { text = "staged", workspaceRoot = "/w", kind = "question", submitted = true } }, 0, false, 1
	end
	store.rewrite = function()
		return false, "EACCES"
	end
	history._set_store(store)

	local removed, ok
	local notifications = capture_notifications(function()
		removed, ok = history.clear()
	end)

	eq(ok, false)
	eq(removed, 0)
	assert(notifications[1] and notifications[1]:match("could not write"), vim.inspect(notifications))
end)

test("a read failure is not treated as an empty history", function()
	reset_history()
	local store = history_store.fake()
	store.load = function()
		return {}, 0, true, 0
	end
	history._set_store(store)

	local notifications = capture_notifications(function()
		eq(#history.entries(), 0)
	end)

	assert(notifications[1] and notifications[1]:match("history is unavailable"), vim.inspect(notifications))
end)

test("a row with a non-string workspaceRoot is normalized instead of raising", function()
	reset_history()
	history._set_store(history_store.fake({
		{ text = "malformed", workspaceRoot = {}, kind = 42 },
		{ text = "fine", workspaceRoot = "/w", kind = "question" },
	}))

	-- Previously this raised inside dedup_key, outside the pcall, aborting the
	-- load mid-file and breaking :VantageStatus.
	local entries = history.entries()
	eq(#entries, 2)
	for _, e in ipairs(entries) do
		eq(type(e.workspaceRoot), "string")
		eq(type(e.kind), "string")
	end
end)

test("appending to the composition mid-cycle survives cycling back", function()
	local vantage = require("vantage")
	in_workspace()
	vantage.compose_append("staged work")
	local params = require("vantage.context").scoped({})
	history.record({ kind = "question", text = "recalled", workspaceRoot = params.workspaceRoot })

	vantage.compose()
	local buf = require("vantage.composition").get_bufnr()
	vim.api.nvim_set_current_win(require("vantage.ui.window").window_in_current_tabpage(buf))
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Up>", true, false, true), "x", false)

	vantage.compose_append("APPENDED MID CYCLE")
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Down>", true, false, true), "x", false)

	-- The append ended the walk, so <Down> must not restore the pre-cycle draft
	-- over it.
	assert(require("vantage.composition").content():match("APPENDED MID CYCLE"), require("vantage.composition").content())
end)

test("a prompt float wiped without the cancel keymap still records its draft", function()
	local vantage = require("vantage")
	in_workspace()

	vantage.prompt({ on_submit = function() end })
	local win = require("vantage.ui").last_float_win()
	vim.api.nvim_buf_set_lines(require("vantage.ui").last_float_buf(), 0, -1, false, { "rescued by autocmd" })
	-- Not the cancel keymap: any teardown must rescue, since the buffer is wipe.
	vim.api.nvim_win_close(win, true)

	local entries = history.entries()
	eq(#entries, 1)
	eq(entries[1].text, "rescued by autocmd")
	eq(entries[1].submitted, false)
end)

test("a submitted prompt is not also recorded as an abandoned draft on wipe", function()
	local vantage = require("vantage")
	in_workspace()

	vantage.prompt({ params = require("vantage.context").scoped({}), on_submit = function() end })
	submit_prompt_buffer("sent once")

	local entries = history.entries()
	eq(#entries, 1)
	eq(entries[1].submitted, true)
end)

test("composition send with no prior append records the real workspace", function()
	local vantage = require("vantage")
	in_workspace({ composition = { on_send = function() return true end } })
	local expected = require("vantage.context").scoped({}).workspaceRoot

	-- No compose_append first, so origin_context is never populated.
	vantage.compose()
	local buf = require("vantage.composition").get_bufnr()
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "typed straight in" })
	vantage.compose_send()

	local entries = history.entries()
	eq(#entries, 1)
	eq(entries[1].workspaceRoot, expected)
end)

test("composition refresh rebinds the history cycle keys from new config", function()
	local vantage = require("vantage")
	in_workspace()
	vantage.compose_append("staged")
	local buf = require("vantage.composition").get_bufnr()
	eq(prompt_buffer_mapped(buf, "n", "<Up>"), true)

	vantage.setup({
		backend = { mode = "development" },
		ui = { composition = { keymaps = { history_prev = "<C-p>" } } },
	})

	eq(prompt_buffer_mapped(buf, "n", "<C-p>"), true)
	eq(prompt_buffer_mapped(buf, "n", "<Up>"), false)
end)
