-- walkthrough generation, loading, and rendering
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq
local fresh_buffer = helpers.fresh_buffer
local lua_buffer = helpers.lua_buffer
local temp_workspace = helpers.temp_workspace
local set_buffer_path = helpers.set_buffer_path
local writefile = helpers.writefile
local submit_prompt_buffer = helpers.submit_prompt_buffer
local capture_backend_request = helpers.capture_backend_request

local function setup_walkthrough(root, buffer_lines, pointers)
	local vantage = require("vantage")
	vantage.setup({ backend = { mode = "development" } })
	require("vantage.walkthrough").disarm()
	require("vantage.annotations").clear_all()
	fresh_buffer()
	vim.fn.mkdir(root .. "/lua", "p")
	local file = root .. "/lua/example.lua"
	writefile(file, table.concat(buffer_lines, "\n") .. "\n")
	set_buffer_path(file)
	vim.api.nvim_buf_set_lines(0, 0, -1, false, buffer_lines)
	writefile(root .. "/.vantage/walkthrough.json", vim.json.encode({ version = 1, pointers = pointers }))
	return vim.api.nvim_get_current_buf()
end

test("VantageLoadWalkthrough populates quickfix and annotates open buffers", function()
	local annotations = require("vantage.annotations")
	local root = temp_workspace()
	local bufnr = setup_walkthrough(root, { "local a = 1", "local b = a + 1" }, {
		{ file = "lua/example.lua", line = 2, anchor = "local b = a + 1", description = "b derives from a." },
	})

	vim.cmd("VantageLoadWalkthrough")

	local qf = vim.fn.getqflist()
	assert(#qf == 1, vim.inspect(qf))
	eq(qf[1].lnum, 2)
	eq(qf[1].text, "b derives from a.")

	local marks = annotations.current_marks(bufnr)
	assert(#marks == 1, vim.inspect(marks))
	eq(marks[1][4].virt_lines[1][1][1], "b derives from a.")
	eq(marks[1][4].virt_lines_above, true)

	vim.cmd("cclose")
	require("vantage.walkthrough").disarm()
	annotations.clear_all()
end)

test("VantageLoadWalkthrough marks pointers whose anchor drifted as stale", function()
	local annotations = require("vantage.annotations")
	local root = temp_workspace()
	local bufnr = setup_walkthrough(root, { "local a = 1", "local b = a + 999" }, {
		{ file = "lua/example.lua", line = 2, anchor = "local b = a + 1", description = "b derives from a." },
	})

	vim.cmd("VantageLoadWalkthrough")

	local marks = annotations.current_marks(bufnr)
	assert(#marks == 1, vim.inspect(marks))
	eq(marks[1][4].virt_lines[1][1][1], "[stale] b derives from a.")

	vim.cmd("cclose")
	require("vantage.walkthrough").disarm()
	annotations.clear_all()
end)

test("walkthrough renders on buffer entry and VantageAnnotationClear disarms it", function()
	local annotations = require("vantage.annotations")
	local root = temp_workspace()
	local bufnr = setup_walkthrough(root, { "local a = 1", "local b = a + 1" }, {
		{ file = "lua/example.lua", line = 2, anchor = "local b = a + 1", description = "b derives from a." },
	})

	vim.cmd("VantageLoadWalkthrough")
	vim.cmd("cclose")

	-- Wipe just this buffer's marks, then re-entering it should re-render via the autocmd.
	annotations.clear(bufnr)
	assert(#annotations.current_marks(bufnr) == 0, "expected a clean buffer")
	vim.cmd("enew")
	vim.api.nvim_set_current_buf(bufnr)
	assert(#annotations.current_marks(bufnr) == 1, "expected autocmd to re-render on entry")

	-- Clearing disarms: a later entry must not re-render.
	vim.cmd("VantageAnnotationClear")
	assert(#annotations.current_marks(bufnr) == 0, "expected clear to remove marks")
	vim.cmd("enew")
	vim.api.nvim_set_current_buf(bufnr)
	assert(#annotations.current_marks(bufnr) == 0, "expected no re-render after disarm")

	require("vantage.walkthrough").disarm()
	annotations.clear_all()
end)

test("VantageGenerateWalkthrough sends a generateWalkthrough request and loads the written walkthrough", function()
	local vantage = require("vantage")
	local root = temp_workspace()
	vim.fn.mkdir(root .. "/lua", "p")
	local file = root .. "/lua/example.lua"
	writefile(file, "local a = 1\nlocal b = a + 1\n")

	local captured = capture_backend_request({
		ok = true,
		result = {
			kind = "walkthrough",
			path = root .. "/.vantage/walkthrough.json",
			pointerCount = 1,
		},
	}, function()
		vantage.setup({ backend = { mode = "development" } })
		require("vantage.walkthrough").disarm()
		require("vantage.annotations").clear_all()
		fresh_buffer()
		set_buffer_path(file)
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local a = 1", "local b = a + 1" })

		-- Stand in for the pi agent actually writing the artifact before responding.
		writefile(root .. "/.vantage/walkthrough.json", vim.json.encode({
			version = 1,
			pointers = {
				{ file = "lua/example.lua", line = 2, anchor = "local b = a + 1", description = "b derives from a." },
			},
		}))

		vim.cmd("VantageGenerateWalkthrough explain how b is derived")
	end)

	eq(captured.method, "generateWalkthrough")
	eq(captured.params.prompt, "explain how b is derived")

	local qf = vim.fn.getqflist()
	assert(#qf == 1, vim.inspect(qf))
	eq(qf[1].lnum, 2)
	eq(qf[1].text, "b derives from a.")

	vim.cmd("cclose")
	require("vantage.walkthrough").disarm()
	require("vantage.annotations").clear_all()
end)

test("ranged VantageGenerateWalkthrough requires an explicit prompt", function()
	local vantage = require("vantage")

	local captured = capture_backend_request({
		ok = true,
		result = {
			kind = "walkthrough",
			path = "/tmp/does-not-exist/.vantage/walkthrough.json",
			pointerCount = 0,
		},
	}, function()
		vantage.setup({ backend = { mode = "development" } })
		lua_buffer({
			"local value = 1",
			"return value",
		})

		vim.cmd("1,2VantageGenerateWalkthrough")
		submit_prompt_buffer("walk through how value is used")
	end)

	eq(captured.method, "generateWalkthrough")
	eq(captured.params.prompt, "walk through how value is used")
	eq(captured.params.range, {
		startLine = 1,
		startCharacter = 1,
		endLine = 2,
		endCharacter = 12,
	})
end)
