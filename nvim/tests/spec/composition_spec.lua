-- the composition staging buffer: append/separators, persistence, and send
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq
local composition = require("vantage.composition")
local lua_buffer = helpers.lua_buffer
local capture_notifications = helpers.capture_notifications
local capture_backend_request = helpers.capture_backend_request
local prompt_buffer_mapped = helpers.prompt_buffer_mapped
local temp_workspace = helpers.temp_workspace
local writefile = helpers.writefile

---Fresh composition state: wipe any existing composition buffer so each test
---starts from "nothing staged", since the module intentionally keeps one global
---buffer alive across calls.
local function reset_composition(config)
	local vantage = require("vantage")
	local existing = require("vantage.composition").get_bufnr()
	if existing then
		pcall(vim.api.nvim_buf_delete, existing, { force = true })
	end
	lua_buffer({ "local a = 1" })
	vantage.setup(vim.tbl_deep_extend("force", { backend = { mode = "development" } }, config or {}))
	return vantage
end

-- Delegates to the production lookup so these tests exercise its tabpage
-- scoping rather than re-implementing a global scan that would mask it.
local function composition_win()
	local buf = composition.get_bufnr()
	if not buf then
		return nil
	end
	return require("vantage.ui.window").window_in_current_tabpage(buf)
end

test("compose_append into an empty composition sets the content", function()
	local vantage = reset_composition()

	eq(composition.is_empty(), true)
	eq(vantage.compose_append("first entry"), true)

	eq(composition.content(), "first entry")
	eq(composition.is_empty(), false)
end)

test("compose_append ignores nil and blank text", function()
	local vantage = reset_composition()

	eq(vantage.compose_append(nil), false)
	eq(vantage.compose_append(""), false)
	eq(vantage.compose_append("   \n  "), false)
	eq(composition.is_empty(), true)
end)

test("compose_append separates entries with the configured rule", function()
	local vantage = reset_composition()

	vantage.compose_append("first")
	vantage.compose_append("second")

	eq(composition.content(), "first\n\n---\n\nsecond")
end)

test("compose_append honors a configured separator", function()
	local vantage = reset_composition({ composition = { separator = "***" } })

	vantage.compose_append("first")
	vantage.compose_append("second")

	eq(composition.content(), "first\n\n***\n\nsecond")
end)

test("compose_append with separation=blank uses blank-line separation", function()
	local vantage = reset_composition()

	vantage.compose_append("@a.lua", { separation = "blank" })
	vantage.compose_append("@b.lua", { separation = "blank" })

	eq(composition.content(), "@a.lua\n\n@b.lua")
end)

test("staged content survives closing the composition window", function()
	local vantage = reset_composition()
	vantage.compose_append("do not lose me")
	vantage.compose()

	local win = composition_win()
	assert(win, "expected the composition window to be open")
	vim.api.nvim_win_close(win, false)

	-- The dotfiles predecessor used bufhidden="wipe", which destroyed the buffer
	-- (and everything staged) the moment its window closed.
	eq(composition_win(), nil)
	eq(composition.content(), "do not lose me")
end)

test("composition buffer is recoverable while hidden", function()
	local vantage = reset_composition()
	vantage.compose_append("staged")
	local buf = require("vantage.composition").get_bufnr()

	-- Appending never shows the buffer, so it is already hidden here.
	eq(composition_win(), nil)

	-- Recovery scan works only because the buffer still exists when hidden.
	eq(require("vantage.composition").get_bufnr(), buf)
	eq(composition.content(), "staged")
end)

test("compose reopens the composition buffer with its content intact", function()
	local vantage = reset_composition()
	vantage.compose_append("still here")
	vantage.compose()
	vim.api.nvim_win_close(composition_win(), false)

	vantage.compose()

	assert(composition_win(), "expected compose() to reopen the window")
	eq(composition.content(), "still here")
end)

test("compose_append stages without opening or focusing the window", function()
	local vantage = reset_composition()
	local origin = vim.api.nvim_get_current_win()

	vantage.compose_append("staged")

	-- Staging happens constantly while you work, so it must not put a split on
	-- screen or move the cursor. Visibility is the toggle's job.
	eq(vim.api.nvim_get_current_win(), origin)
	eq(composition_win(), nil)
	eq(composition.content(), "staged")
end)

test("compose toggles the window closed when it is already visible", function()
	local vantage = reset_composition()
	vantage.compose_append("staged")

	vantage.compose()
	assert(composition_win(), "expected the toggle to open the window")

	vantage.compose()
	eq(composition_win(), nil)
	-- Toggling closed only hides it; the content survives.
	eq(composition.content(), "staged")
end)

test("compose focuses the composition window", function()
	local vantage = reset_composition()
	vantage.compose_append("staged")

	vantage.compose()

	eq(vim.api.nvim_get_current_win(), composition_win())
end)

test("compose_clear empties the buffer without destroying it", function()
	local vantage = reset_composition()
	vantage.compose_append("throwaway")
	local buf = require("vantage.composition").get_bufnr()

	vantage.compose_clear()

	eq(composition.is_empty(), true)
	assert(vim.api.nvim_buf_is_valid(buf), "expected the buffer to survive clearing")
	eq(require("vantage.composition").get_bufnr(), buf)
end)

test("compose_send on an empty composition warns and does not call on_send", function()
	local called = false
	local vantage = reset_composition({
		composition = {
			on_send = function()
				called = true
			end,
		},
	})

	local notifications = capture_notifications(function()
		vantage.compose_send()
	end)

	assert(not called, "expected on_send not to run for an empty composition")
	assert(notifications[1] and notifications[1]:match("empty"), vim.inspect(notifications))
end)

test("compose_send passes the trimmed staged text to on_send", function()
	local received
	local vantage = reset_composition({
		composition = {
			on_send = function(text)
				received = text
				return true
			end,
		},
	})

	vantage.compose_append("first")
	vantage.compose_append("second")
	vantage.compose_send()

	eq(received, "first\n\n---\n\nsecond")
end)

test("compose_send clears and closes after a successful on_send", function()
	local vantage = reset_composition({
		composition = {
			on_send = function()
				return true
			end,
		},
	})

	vantage.compose_append("send me")
	eq(vantage.compose_send(), true)

	eq(composition.is_empty(), true)
	eq(composition_win(), nil)
end)

test("compose_send leaves content staged when on_send returns false", function()
	local vantage = reset_composition({
		composition = {
			on_send = function()
				return false
			end,
		},
	})

	vantage.compose_append("keep me on failure")
	eq(vantage.compose_send(), false)

	-- Clearing on a failed send would lose the user's staged work.
	eq(composition.content(), "keep me on failure")
end)

test("compose_send respects clear_on_send and close_on_send being disabled", function()
	local vantage = reset_composition({
		composition = {
			clear_on_send = false,
			close_on_send = false,
			on_send = function()
				return true
			end,
		},
	})

	vantage.compose_append("persist")
	vantage.compose()
	vantage.compose_send()

	eq(composition.content(), "persist")
	assert(composition_win(), "expected the window to stay open")
end)

test("compose_send with no on_send routes through the question flow", function()
	local vantage = reset_composition()

	local captured = capture_backend_request({
		ok = true,
		result = { kind = "explanation", markdown = "answer" },
	}, function()
		vantage.compose_append("what does this do?")
		vantage.compose_send()
	end)

	eq(captured.method, "questionSelection")
	eq(captured.params.question, "what does this do?")
end)

test("is_composition_buffer identifies the composition buffer only", function()
	local vantage = reset_composition()
	vantage.compose_append("staged")
	local buf = require("vantage.composition").get_bufnr()

	eq(vantage.is_composition_buffer(buf), true)
	eq(vantage.is_composition_buffer(vim.api.nvim_create_buf(false, true)), false)
	eq(vantage.is_composition_buffer(99999), false)
end)

test("composition keymaps scope send to both modes and close to normal only", function()
	local vantage = reset_composition()
	vantage.compose_append("staged")
	local buf = require("vantage.composition").get_bufnr()

	eq(prompt_buffer_mapped(buf, "n", "<C-g>"), true)
	eq(prompt_buffer_mapped(buf, "i", "<C-g>"), true)

	-- `q` must stay literal in insert mode: this is a buffer users type prose into.
	eq(prompt_buffer_mapped(buf, "n", "q"), true)
	eq(prompt_buffer_mapped(buf, "i", "q"), false)
end)

test("composition window shows a keybind hint statusline", function()
	local vantage = reset_composition()
	vantage.compose_append("staged")
	vantage.compose()

	eq(vim.api.nvim_get_option_value("statusline", { win = composition_win() }), " send <C-g>  close q ")
end)

test("composition window has no statusline hint when ui.keybind_hints is false", function()
	local vantage = reset_composition({ ui = { keybind_hints = false } })
	vantage.compose_append("staged")
	vantage.compose()

	local statusline = vim.api.nvim_get_option_value("statusline", { win = composition_win() })
	assert(not statusline:match("send"), "expected no keybind hint, got: " .. statusline)
end)

test("compose_append warns on an unknown separation and falls back to the rule", function()
	local vantage = reset_composition()
	vantage.compose_append("first")

	local notifications = capture_notifications(function()
		vantage.compose_append("second", { separation = "***" })
	end)

	-- "***" is a rule *string*, not a style: config.separator owns the text.
	assert(notifications[1] and notifications[1]:match("unknown composition separation"), vim.inspect(notifications))
	eq(composition.content(), "first\n\n---\n\nsecond")
end)

test("compose_send refuses a non-function on_send instead of routing to the model", function()
	local vantage = reset_composition({ composition = { on_send = "not a function" } })
	vantage.compose_append("staged")

	local captured = capture_backend_request(nil, function()
		local notifications = capture_notifications(function()
			eq(vantage.compose_send(), false)
		end)
		assert(notifications[1] and notifications[1]:match("must be a function"), vim.inspect(notifications))
	end)

	eq(captured.method, nil)
	eq(composition.content(), "staged")
end)

test("compose_send attributes the unconfigured fallback to the origin buffer, not the composition buffer", function()
	local vantage = reset_composition()
	local root = temp_workspace()
	writefile(root .. "/origin.lua", "local a = 1\n")
	vim.cmd("edit " .. root .. "/origin.lua")

	local captured = capture_backend_request({
		ok = true,
		result = { kind = "explanation", markdown = "answer" },
	}, function()
		vantage.compose_append("what does this do?")
		vantage.compose_send()
	end)

	eq(captured.method, "questionSelection")
	assert(captured.params.filePath:match("origin%.lua"), captured.params.filePath)
	assert(not captured.params.filePath:match("VantageComposition"), captured.params.filePath)
end)

test("compose_send only clears after the unconfigured fallback responds", function()
	local vantage = reset_composition()
	local backend = require("vantage.backend")
	local original = backend.request
	local respond
	backend.request = function(_, _, cb)
		respond = cb
		return "pending"
	end

	vantage.compose_append("staged")
	vantage.compose_send()

	-- Request in flight: the staged text must still be recoverable.
	eq(composition.content(), "staged")
	respond({ ok = true, result = { kind = "explanation", markdown = "answer" } })
	eq(composition.is_empty(), true)

	backend.request = original
end)

test("composition window lookup is scoped to the current tabpage", function()
	local vantage = reset_composition()
	vantage.compose_append("staged")
	vantage.compose()
	local buf = composition.get_bufnr()
	assert(composition_win(), "expected a window in this tabpage")

	vim.cmd("tabnew")
	-- The other tab's window must not be treated as this tab's.
	eq(composition_win(), nil)

	vantage.compose()
	local win = composition_win()
	assert(win, "expected compose() to open a window in the new tabpage")
	eq(vim.api.nvim_win_get_buf(win), buf)
	eq(vim.api.nvim_get_current_tabpage(), vim.api.nvim_win_get_tabpage(win))

	vim.cmd("tabclose")
end)

test("composition refresh rebinds keymaps after a later setup", function()
	local vantage = reset_composition()
	vantage.compose_append("staged")
	local buf = composition.get_bufnr()
	eq(prompt_buffer_mapped(buf, "n", "<C-g>"), true)

	vantage.setup({ backend = { mode = "development" }, ui = { composition = { keymaps = { send = "<C-s>" } } } })

	eq(prompt_buffer_mapped(buf, "n", "<C-s>"), true)
	eq(prompt_buffer_mapped(buf, "n", "<C-g>"), false)
end)

test("composition warns on exit when content is still staged", function()
	local vantage = reset_composition()
	vantage.compose_append("unsent work")

	local notifications = capture_notifications(function()
		vim.cmd("doautocmd VimLeavePre")
	end)

	assert(
		notifications[1] and notifications[1]:match("still staged"),
		"expected an exit warning, got: " .. vim.inspect(notifications)
	)
end)
