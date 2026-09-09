-- edit / :VantageEdit
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq
local lua_buffer = helpers.lua_buffer
local submit_prompt_buffer = helpers.submit_prompt_buffer
local capture_notifications = helpers.capture_notifications
local capture_backend_request = helpers.capture_backend_request
local with_ui_input = helpers.with_ui_input

test("VantageEdit forwards a runtime= token to the backend", function()
	local vantage = require("vantage")

	local captured = capture_backend_request(nil, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({ "local value = 1" })
		vim.cmd("VantageEdit runtime=completion rename value to count")
	end)

	-- Edit used to reject this outright, because its result arrived via a
	-- submit_edit tool call that completion mode had no equivalent for.
	eq(captured.method, "editSelection")
	eq(captured.params.runtime, "completion")
end)

test("VantageEdit rejects an invalid runtime value", function()
	local vantage = require("vantage")
	vantage.setup({ backend = { mode = "development" } })
	lua_buffer({ "local value = 1" })

	local captured
	local notifications = capture_notifications(function()
		captured = capture_backend_request(nil, function()
			vim.cmd("VantageEdit runtime=telepathy rename value to count")
		end)
	end)

	eq(captured.method, nil)
	assert(notifications[1] and notifications[1]:match("invalid runtime"), vim.inspect(notifications))
end)

test("VantageEdit in completion mode sends file scope with the whole buffer", function()
	local vantage = require("vantage")

	local captured = capture_backend_request(nil, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({ "local value = 1", "return value" })
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		vim.cmd("VantageEdit runtime=completion rename value to count")
	end)

	-- Completion mode has no tools, so it needs the whole file to author
	-- SEARCH blocks against.
	eq(captured.method, "editSelection")
	eq(captured.params.scope, "file")
	eq(captured.params.scopeText, "local value = 1\nreturn value")
	eq(captured.params.range.startLine, 1)
	eq(captured.params.range.endLine, 2)
end)

test("VantageEdit in agent mode sends no scope and keeps cursor-line scoping", function()
	local vantage = require("vantage")

	local captured = capture_backend_request(nil, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({ "local value = 1", "return value" })
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		vim.cmd("VantageEdit rename value to count")
	end)

	-- Agent mode delegates the whole edit to Pi. Scope and SEARCH/REPLACE are
	-- completion-only concepts.
	eq(captured.params.scope, nil)
	eq(captured.params.scopeText, "local value = 1")
	eq(captured.params.range.startLine, 1)
	eq(captured.params.range.endLine, 1)
end)

test("VantageEdit in agent mode does not apply replacement text in Neovim", function()
	local vantage = require("vantage")

	capture_backend_request({
		ok = true,
		result = { kind = "edit_applied", summary = "Pi edited the file." },
	}, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({ "local value = 1", "return value" })
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		vim.cmd("VantageEdit rename value to count")
	end)

	eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "local value = 1", "return value" })
end)

test("VantageEdit in completion mode applies hunks from an edits response", function()
	local vantage = require("vantage")

	capture_backend_request({
		ok = true,
		result = {
			kind = "edits",
			hunks = { { search = "local value = 1", replace = "local count = 1" } },
		},
	}, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({ "local value = 1", "return value" })
		vim.cmd("VantageEdit runtime=completion rename value to count")
	end)

	eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "local count = 1", "return value" })
end)

test("VantageEdit applies several hunks from one response", function()
	local vantage = require("vantage")

	capture_backend_request({
		ok = true,
		result = {
			kind = "edits",
			hunks = {
				{ search = "local a = 1", replace = "local a = 11" },
				{ search = "local c = 3", replace = "local c = 33" },
			},
		},
	}, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({ "local a = 1", "local b = 2", "local c = 3" })
		vim.cmd("VantageEdit runtime=completion bump a and c")
	end)

	eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "local a = 11", "local b = 2", "local c = 33" })
end)

test("VantageEdit reports hunks that did not match and applies the rest", function()
	local vantage = require("vantage")
	local target

	local notifications = capture_notifications(function()
		capture_backend_request({
			ok = true,
			result = {
				kind = "edits",
				hunks = {
					{ search = "local a = 1", replace = "local a = 11" },
					{ search = "local nope = 9", replace = "x" },
				},
			},
		}, function()
			vantage.setup({ backend = { mode = "development" } })
			lua_buffer({ "local a = 1", "local b = 2" })
			target = vim.api.nvim_get_current_buf()
			vim.cmd("VantageEdit runtime=completion bump a")
		end)
	end)

	-- Assert against the edited buffer by handle: reporting opens a markdown
	-- float, so buffer 0 is no longer the file.
	eq(vim.api.nvim_buf_get_lines(target, 0, -1, false), { "local a = 11", "local b = 2" })

	-- Must name the *reason*. The previous assertion accepted any message
	-- containing "1" and "edit", which the plain success notification satisfies
	-- -- so it could not fail if reporting were removed.
	local reported = table.concat(notifications, "\n")
	assert(reported:match("skipped"), vim.inspect(notifications))
	assert(reported:match("1 edit block"), vim.inspect(notifications))
end)

test("VantageEdit reports a no-op response as success, not an error", function()
	local vantage = require("vantage")

	local notifications = capture_notifications(function()
		capture_backend_request({
			ok = true,
			result = { kind = "edits", hunks = {} },
		}, function()
			vantage.setup({ backend = { mode = "development" } })
			lua_buffer({ "local a = 1" })
			vim.cmd("VantageEdit runtime=completion nothing to do")
		end)
	end)

	-- The prompt invites zero blocks ("if no edit is needed, return no blocks at
	-- all"), so surfacing that as an error trains distrust of real failures.
	local reported = table.concat(notifications, "\n")
	assert(reported:match("no edit needed"), vim.inspect(notifications))
	assert(not reported:lower():match("failed"), vim.inspect(notifications))
end)

test("VantageEdit reports applied blocks as blocks, not lines", function()
	local vantage = require("vantage")

	local notifications = capture_notifications(function()
		capture_backend_request({
			ok = true,
			result = {
				kind = "edits",
				hunks = {
					{ search = "local a = 1", replace = "local a = 11\nlocal extra = 1" },
					{ search = "local c = 3", replace = "local c = 33" },
				},
			},
		}, function()
			vantage.setup({ backend = { mode = "development" } })
			lua_buffer({ "local a = 1", "local b = 2", "local c = 3" })
			vim.cmd("VantageEdit runtime=completion bump a and c")
		end)
	end)

	-- The hunk count used to be rendered as a line count, understating a
	-- 2-block, 3-line change as "2 line(s)".
	local reported = table.concat(notifications, "\n")
	assert(reported:match("2 edit block"), vim.inspect(notifications))
end)

test("VantageEdit reports a wiped buffer instead of raising in the callback", function()
	local vantage = require("vantage")

	local notifications = capture_notifications(function()
		capture_backend_request({
			ok = true,
			result = { kind = "edit_applied", summary = "Pi edited the file." },
		}, function()
			vantage.setup({ backend = { mode = "development" } })
			lua_buffer({ "local value = 1" })
			local doomed = vim.api.nvim_get_current_buf()
			vim.cmd("1VantageEdit rename value to count")
			-- The response callback only synchronizes Neovim with Pi's external edit.
			pcall(vim.api.nvim_buf_delete, doomed, { force = true })
		end)
	end)

	-- Whatever happened, it must not have been an unhandled Lua error.
	assert(#notifications >= 1, vim.inspect(notifications))
end)

test("VantageEdit on a range sends selection scope and replaces just that range", function()
	local vantage = require("vantage")

	local captured = capture_backend_request({
		ok = true,
		result = { kind = "edit", replacementText = "local count = 1" },
	}, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({ "local value = 1", "return value" })
		vim.cmd("1VantageEdit runtime=completion rename value to count")
	end)

	eq(captured.params.scope, "selection")
	eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "local count = 1", "return value" })
end)

test("VantageEdit opens prompt buffer for missing instruction", function()
	local vantage = require("vantage")

	-- Default runtime is agent, which lets Pi edit files directly.
	local captured = capture_backend_request({
		ok = true,
		result = {
			kind = "edit_applied",
			summary = "Pi edited the file.",
		},
	}, function()
		vantage.setup({
			backend = { mode = "development" },
			ui = {
				input = {
					provider = "ui2",
					edit = {
						prompt = "UI2 edit: ",
					},
				},
			},
		})
		lua_buffer({
			"local value = 1",
			"return value",
		})
		vim.api.nvim_win_set_cursor(0, { 1, 0 })

		with_ui_input(function()
			error("expected VantageEdit to use prompt buffer instead of vim.ui.input")
		end, function()
			vim.cmd("VantageEdit")
			submit_prompt_buffer("rename value to count")
		end)
	end)

	eq(captured.method, "editSelection")
	eq(captured.params.instruction, "rename value to count")
	eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), {
		"local value = 1",
		"return value",
	})
end)

test("VantageEdit agent mode leaves explicit range application to Pi", function()
	local vantage = require("vantage")

	local captured = capture_backend_request({
		ok = true,
		result = {
			kind = "edit_applied",
			summary = "Pi edited the file.",
		},
	}, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({
			"local a = 1",
			"local b = 2",
			"return a + b",
		})

		vim.cmd("1,2VantageEdit combine the locals")
	end)

	eq(captured.method, "editSelection")
	eq(captured.params.instruction, "combine the locals")
	eq(captured.params.range, {
		startLine = 1,
		startCharacter = 1,
		endLine = 2,
		endCharacter = 11,
	})
	eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), {
		"local a = 1",
		"local b = 2",
		"return a + b",
	})
end)

-- --- Applying SEARCH/REPLACE hunks ---
--
-- The matcher (vantage.search_replace) is tested against plain strings in
-- search_replace_spec. These cover the buffer half: ordering, and the single
-- undo step that is this feature's entire safety net.

local buffer_edit = require("vantage.buffer_edit")
local search_replace = require("vantage.search_replace")

local function buffer_with(lines)
	helpers.fresh_buffer()
	vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
	-- A fresh buffer starts modified-but-empty; clear undo history so the tests
	-- below measure only their own edits.
	vim.bo.modified = false
	return vim.api.nvim_get_current_buf()
end

local function buffer_text(buf)
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function apply(buf, hunks)
	local resolved, failures = search_replace.resolve(buffer_text(buf), hunks)
	local applied = buffer_edit.apply_hunks(buf, resolved)
	return applied, failures
end

test("apply_hunks applies a single hunk", function()
	local buf = buffer_with({ "one", "two", "three" })

	local applied = apply(buf, { { search = "two", replace = "TWO" } })

	eq(applied, 1)
	eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "one", "TWO", "three" })
end)

test("apply_hunks applies several hunks to the right lines", function()
	local buf = buffer_with({ "one", "two", "three", "four" })

	apply(buf, {
		{ search = "one", replace = "ONE" },
		{ search = "four", replace = "FOUR" },
	})

	eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "ONE", "two", "three", "FOUR" })
end)

test("apply_hunks stays correct when an earlier hunk changes the line count", function()
	local buf = buffer_with({ "one", "two", "three" })

	-- Applying top-down would shift "three" out from under its resolved range.
	apply(buf, {
		{ search = "one", replace = "one-a\none-b\none-c" },
		{ search = "three", replace = "THREE" },
	})

	eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "one-a", "one-b", "one-c", "two", "THREE" })
end)

test("apply_hunks deletes lines for an empty replacement", function()
	local buf = buffer_with({ "one", "two", "three" })

	apply(buf, { { search = "two", replace = "" } })

	eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "one", "three" })
end)

test("a multi-hunk edit is a single undo step", function()
	local buf = buffer_with({ "one", "two", "three", "four" })

	-- Measured as an undo-sequence delta rather than by undoing and comparing
	-- text: the buffer's own population is an undoable change too, so a
	-- content-based check can only tell you *something* was reverted, not how
	-- many steps it took.
	local before = vim.fn.undotree().seq_cur

	apply(buf, {
		{ search = "one", replace = "ONE" },
		{ search = "three", replace = "THREE" },
		{ search = "four", replace = "FOUR" },
	})
	eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "ONE", "two", "THREE", "FOUR" })

	-- `u` is the whole safety net for this feature: one press must revert the
	-- entire edit, not peel off one hunk at a time.
	eq(vim.fn.undotree().seq_cur - before, 1)
end)

test("undoing a multi-hunk edit restores every hunk at once", function()
	local buf = buffer_with({ "one", "two", "three", "four" })

	apply(buf, {
		{ search = "one", replace = "ONE" },
		{ search = "four", replace = "FOUR" },
	})
	vim.cmd("silent undo")

	eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "one", "two", "three", "four" })
end)

test("apply_hunks applies what matched and leaves failures to the caller", function()
	local buf = buffer_with({ "one", "two" })

	local applied, failures = apply(buf, {
		{ search = "one", replace = "ONE" },
		{ search = "nope", replace = "X" },
	})

	eq(applied, 1)
	eq(#failures, 1)
	eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "ONE", "two" })
end)

test("apply_hunks with nothing resolved leaves the buffer untouched", function()
	local buf = buffer_with({ "one", "two" })

	local applied = buffer_edit.apply_hunks(buf, {})

	eq(applied, 0)
	eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "one", "two" })
end)

test("apply_hunks re-indents a dedented replacement at the match site", function()
	local buf = buffer_with({ "function M.f()", "\tlocal a = 1", "end" })

	apply(buf, { { search = "local a = 1", replace = "local a = 2" } })

	eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "function M.f()", "\tlocal a = 2", "end" })
end)

test("apply_hunks replaces a multi-line search block entirely", function()
	local buf = buffer_with({ "one", "two", "three", "four" })

	apply(buf, { { search = "two\nthree", replace = "MERGED" } })

	-- Consuming only the first line of the match would leave "three" behind.
	eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "one", "MERGED", "four" })
end)

test("apply_hunks handles a multi-line hunk followed by another", function()
	local buf = buffer_with({ "a", "b", "c", "d", "e" })

	apply(buf, {
		{ search = "b\nc", replace = "BC" },
		{ search = "e", replace = "E" },
	})

	eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "BC", "d", "E" })
end)

test("apply_hunks deletes a whole multi-line block", function()
	local buf = buffer_with({ "keep", "drop1", "drop2", "keep2" })

	apply(buf, { { search = "drop1\ndrop2", replace = "" } })

	eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "keep", "keep2" })
end)

test("toggling the runtime in the edit prompt buffer changes what is sent", function()
	local vantage = require("vantage")

	local captured = capture_backend_request(nil, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({ "local value = 1" })
		vim.cmd("VantageEdit")

		-- Drive the real keymap rather than reaching into module state, so this
		-- fails if the binding stops being wired to the toggle.
		local buf = vim.api.nvim_get_current_buf()
		for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
			if (map.desc or ""):match("Toggle Vantage prompt runtime") and map.callback then
				map.callback()
			end
		end
		submit_prompt_buffer("rename value to count")
	end)

	eq(captured.method, "editSelection")
	-- Default is agent; one toggle must reach the backend as completion.
	eq(captured.params.runtime, "completion")
end)

test("the edit prompt buffer default runtime comes from config", function()
	local vantage = require("vantage")

	local captured = capture_backend_request(nil, function()
		vantage.setup({
			backend = { mode = "development" },
			commands = { edit = { runtime = "completion" } },
		})
		lua_buffer({ "local value = 1" })
		vim.cmd("VantageEdit")
		submit_prompt_buffer("rename value to count")
	end)

	eq(captured.params.runtime, "completion")
end)

test("VantageEdit refuses a whole-file completion edit above the line cap", function()
	local vantage = require("vantage")
	local captured

	local notifications = capture_notifications(function()
		captured = capture_backend_request(nil, function()
			vantage.setup({ backend = { mode = "development" }, commands = { edit = { max_file_lines = 3 } } })
			lua_buffer({ "a", "b", "c", "d", "e" })
			vim.cmd("VantageEdit runtime=completion rewrite this")
		end)
	end)

	-- Shipping every line into one call either errors on context length after a
	-- long wait or truncates; refusing up front is cheaper and actionable.
	eq(captured.method, nil)
	local reported = table.concat(notifications, "\n")
	assert(reported:match("runtime=agent"), vim.inspect(notifications))
end)

test("VantageEdit allows a whole-file edit within the cap", function()
	local vantage = require("vantage")

	local captured = capture_backend_request(nil, function()
		vantage.setup({ backend = { mode = "development" }, commands = { edit = { max_file_lines = 100 } } })
		lua_buffer({ "a", "b" })
		vim.cmd("VantageEdit runtime=completion rewrite this")
	end)

	eq(captured.method, "editSelection")
	eq(captured.params.scope, "file")
end)

test("VantageEdit does not apply the file cap to a selection", function()
	local vantage = require("vantage")

	local captured = capture_backend_request(nil, function()
		vantage.setup({ backend = { mode = "development" }, commands = { edit = { max_file_lines = 1 } } })
		lua_buffer({ "a", "b", "c" })
		vim.cmd("1,2VantageEdit runtime=completion rewrite this")
	end)

	-- The cap exists because file scope ships everything; a range is bounded.
	eq(captured.method, "editSelection")
	eq(captured.params.scope, "selection")
end)
