-- how annotations render as virtual blocks, and clearing them
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq
local fresh_buffer = helpers.fresh_buffer
local lua_buffer = helpers.lua_buffer
local last_float_text = helpers.last_float_text

test("annotate renders and clear_annotations clears extmarks", function()
	local vantage = require("vantage")
	local commands = require("vantage.commands")
	local annotations = require("vantage.annotations")
	vantage.setup({ backend = { mode = "development" } })

	lua_buffer({
		"local a = 1",
		"local b = a + 1",
	})

	commands.annotate()
	local marks = annotations.current_marks(0)
	assert(#marks > 0, "expected annotation marks")
	local virt_lines = marks[1][4].virt_lines
	assert(virt_lines and virt_lines[1] and virt_lines[1][1][1]:match("Development annotation"), vim.inspect(marks))
	eq(marks[1][4].virt_lines_above, true)
	eq(marks[1][4].virt_text, nil)
	commands.clear_annotations()
	assert(#annotations.current_marks(0) == 0, "expected annotations to clear")
end)

test("annotations render as wrapped above-line virtual blocks", function()
	local vantage = require("vantage")
	local annotations = require("vantage.annotations")
	vantage.setup({ backend = { mode = "development" } })

	lua_buffer({
		"local value = compute_value(input)",
	})
	vim.o.columns = 48

	annotations.render(0, {
		{
			text = "The `compute_value` call is where the incoming `input` crosses into domain-specific transformation logic, so this line is the best anchor for understanding the data flow under the lens.",
			severity = "info",
			range = { startLine = 1, startCharacter = 1, endLine = 1, endCharacter = 32 },
		},
	})

	local marks = annotations.current_marks(0)
	assert(#marks == 1, vim.inspect(marks))
	local details = marks[1][4]
	eq(details.virt_lines_above, true)
	assert(#details.virt_lines >= 2, vim.inspect(details.virt_lines))
	assert(details.virt_lines[1][1][1]:match("compute_value"), vim.inspect(details.virt_lines))
	assert(details.virt_text == nil, vim.inspect(details))
	annotations.clear(0)
end)

test("annotations render additively and overwrite the exact same position", function()
	local vantage = require("vantage")
	local annotations = require("vantage.annotations")
	vantage.setup({ backend = { mode = "development" } })

	lua_buffer({
		"local a = 1",
		"local b = a + 1",
	})

	annotations.render(0, {
		{
			text = "First line annotation.",
			severity = "info",
			range = { startLine = 1, startCharacter = 1, endLine = 1, endCharacter = 0 },
		},
	})
	annotations.render(0, {
		{
			text = "Second line annotation.",
			severity = "info",
			range = { startLine = 2, startCharacter = 1, endLine = 2, endCharacter = 0 },
		},
	})
	annotations.render(0, {
		{
			text = "Updated first line annotation.",
			severity = "info",
			range = { startLine = 1, startCharacter = 1, endLine = 1, endCharacter = 0 },
		},
	})

	local marks = annotations.current_marks(0)
	assert(#marks == 2, vim.inspect(marks))
	local texts = {}
	for _, mark in ipairs(marks) do
		table.insert(texts, mark[4].virt_lines[1][1][1])
	end
	local combined = table.concat(texts, "\n")
	assert(combined:match("Updated first line annotation"), combined)
	assert(combined:match("Second line annotation"), combined)
	assert(not combined:match("First line annotation%."), combined)
end)

test("annotations skip out-of-range lines", function()
	local vantage = require("vantage")
	local annotations = require("vantage.annotations")
	vantage.setup({ backend = { mode = "development" } })

	lua_buffer({ "only one line" })

	local count = annotations.render(0, {
		{
			text = "Out of range.",
			range = {
				startLine = 100,
				startCharacter = 1,
				endLine = 100,
				endCharacter = 0,
			},
		},
	})

	assert(count == 0, "expected no rendered annotations")
	assert(#annotations.current_marks(0) == 0, "expected out-of-range annotation to be skipped")
	assert(not annotations.is_enabled(), "expected annotations to stay disabled")
end)

test("annotate shows a readable empty-result message", function()
	local vantage = require("vantage")
	local commands = require("vantage.commands")
	local annotations = require("vantage.annotations")
	local backend = require("vantage.backend")

	local ok, err = pcall(function()
		backend.stop()
		annotations.clear(0)
		vantage.setup({
			backend = {
				mode = "stdio",
				command = {
					"node",
					"-e",
					[=[
process.stdin.setEncoding('utf8');
let pending = '';
process.stdin.on('data', (chunk) => {
  pending += chunk;
  const lines = pending.split('\n');
  pending = lines.pop() || '';
  for (const line of lines) {
    if (!line.trim()) continue;
    const request = JSON.parse(line);
    console.log(JSON.stringify({
      id: request.id,
      ok: true,
      result: { kind: 'annotations', annotations: [] }
    }));
  }
});
]=],
				},
			},
		})

		fresh_buffer()
		vim.bo.filetype = "lua"
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local value = 42" })

		commands.annotate()
		vim.wait(2000, function()
			local text = last_float_text()
			return text and text:match("No annotations") ~= nil
		end)

		local text = last_float_text()
		assert(text ~= nil, "expected no-annotations float")
		assert(text:match("No annotations"), text)
		assert(#annotations.current_marks(0) == 0, "expected no annotation marks")
		assert(not annotations.is_enabled(), "expected annotations to stay disabled")
	end)

	backend.stop()
	assert(ok, err)
end)
