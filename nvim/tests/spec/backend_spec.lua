-- stdio backend transport: spawn, config, chunking, exit
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq
local fresh_buffer = helpers.fresh_buffer
local last_float_text = helpers.last_float_text

test("default stdio backend command resolves from plugin root", function()
	local state = require("vantage.state")

	eq(state.config.backend.mode, "stdio")
	eq(state.config.backend.command, {
		"node",
		vim.fn.getcwd() .. "/server/out/neovim/stdio-server.js",
	})
	eq(state.config.agent.options, {})
	eq(state.config.completion.options, {})
	eq(state.config.commands.annotate.options, {})
end)

test("stdio backend sends agent and command config from setup", function()
	local vantage = require("vantage")
	local backend = require("vantage.backend")
	local responses = {}

	backend.stop()
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
      result: {
        kind: 'explanation',
        markdown: JSON.stringify({
          config: request.config,
            shape: {
              explainOptionsAreArray: Array.isArray(request.config.commands.explain.options),
              questionOptionsAreArray: Array.isArray(request.config.commands.question.options),
              editOptionsAreArray: Array.isArray(request.config.commands.edit.options)
            }
        })
      }
    }));
  }
});
]=],
			},
		},
		agent = {
			models = {
				{
					name = "test",
					provider = "anthropic",
					model = "claude-test",
				},
			},
			default_model = "test",
			auth = {
				path = "~/.config/pi-ai/auth.json",
			},
			options = {
				timeoutMs = 120000,
				reasoning = "medium",
			},
		},
		commands = {
			annotate = {
				waiting_message_ms = 10,
				options = {
					timeoutMs = 45000,
				},
			},
		},
	})

	backend.request("explainSelection", {}, function(result)
		table.insert(responses, result)
	end)

	vim.wait(3000, function()
		return #responses == 1
	end)
	backend.stop()

	assert(#responses == 1, "expected one stdio response")
	local payload = vim.json.decode(responses[1].result.markdown)
	eq(payload.shape, {
		explainOptionsAreArray = false,
		questionOptionsAreArray = false,
		editOptionsAreArray = false,
	})
	eq(payload.config, {
		completion = {
			options = vim.empty_dict(),
		},
		agent = {
			runtime = "pi",
			provider = "anthropic",
			model = "claude-test",
			auth = {
				path = "~/.config/pi-ai/auth.json",
			},
			options = {
				timeoutMs = 120000,
				reasoning = "medium",
			},
			session_output = {
				history_limit = 10,
			},
		},
		commands = {
			explain = {
				include_lens = true,
				options = vim.empty_dict(),
			},
			question = {
				include_lens = false,
				options = vim.empty_dict(),
			},
			edit = {
				include_lens = false,
				options = vim.empty_dict(),
			},
			annotate = {
				include_lens = true,
				waiting_message_ms = 10,
				options = {
					timeoutMs = 45000,
				},
			},
			search = {
				include_lens = true,
				options = vim.empty_dict(),
			},
			walkthrough = {
				include_lens = true,
				options = vim.empty_dict(),
			},
		},
	})
end)

test("stdio backend reports exit to pending callbacks", function()
	local vantage = require("vantage")
	local backend = require("vantage.backend")
	local responses = {}

	backend.stop()
	vantage.setup({
		backend = {
			mode = "stdio",
			command = {
				"node",
				"-e",
				[=[
process.stdin.resume();
process.stdin.on('data', () => process.exit(7));
]=],
			},
		},
	})

	backend.request("explainSelection", {}, function(result)
		table.insert(responses, result)
	end)

	vim.wait(2000, function()
		return #responses == 1
	end)
	backend.stop()

	assert(#responses == 1, "expected backend exit to invoke pending callback")
	assert(responses[1].ok == false, vim.inspect(responses[1]))
	assert(tostring(responses[1].error.message):match("exited"), vim.inspect(responses[1]))
end)

test("stdio backend handles multiple line-split stdout callbacks", function()
	local vantage = require("vantage")
	local backend = require("vantage.backend")
	local responses = {}
	backend.stop()
	vim.wait(100, function()
		return false
	end)

	vantage.setup({
		backend = {
			mode = "stdio",
			command = {
				"node",
				"-e",
				[=[
process.stdin.setEncoding('utf8');
process.stdin.resume();
let pending = '';
let count = 0;
let writing = false;
const queue = [];
function flushQueue() {
  if (writing || queue.length === 0) return;
  writing = true;
  const response = queue.shift();
  process.stdout.write(response.slice(0, 12));
  setTimeout(() => {
    process.stdout.write(response.slice(12));
    writing = false;
    flushQueue();
  }, 5);
}
process.stdin.on('data', (chunk) => {
  pending += chunk;
  const lines = pending.split('\n');
  pending = lines.pop() || '';
  for (const line of lines) {
    if (!line.trim()) continue;
    count += 1;
    const request = JSON.parse(line);
    const response = JSON.stringify({
      id: request.id,
      ok: true,
      result: { kind: 'explanation', markdown: count === 1 ? 'one' : 'two' }
    }) + '\n';
    queue.push(response);
    flushQueue();
  }
});
]=],
			},
		},
	})

	backend.request("explainSelection", {}, function(result)
		table.insert(responses, result)
	end)
	backend.request("explainSelection", {}, function(result)
		table.insert(responses, result)
	end)

	vim.wait(3000, function()
		return #responses == 2
	end)
	backend.stop()

	assert(#responses == 2, "expected two stdio callbacks to fire")
	eq(responses[1].result, { kind = "explanation", markdown = "one" })
	eq(responses[2].result, { kind = "explanation", markdown = "two" })
end)

test("stdio backend opens a float through explain", function()
	local vantage = require("vantage")
	local commands = require("vantage.commands")
	local backend = require("vantage.backend")

	local ok, err = pcall(function()
		backend.stop()
		vim.wait(100, function()
			return false
		end)

		vantage.setup({
			backend = {
				mode = "stdio",
				command = { "node", "server/out/neovim/stdio-server.js" },
			},
			agent = {
				runtime = "development",
			},
		})
		vantage.set_lens("learning", "I am learning Lua syntax")

		fresh_buffer()
		vim.bo.filetype = "lua"
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local value = 42" })

		commands.explain()
		vim.wait(2000, function()
			local text = last_float_text()
			return text and text:match("Development agent runtime") ~= nil
		end)

		local text = last_float_text()
		assert(text ~= nil, "expected stdio float buffer")
		assert(text:match("Development agent runtime"), text)
	end)

	backend.stop()
	assert(ok, err)
end)

test("stdio backend renders non-empty annotation block", function()
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
				command = { "node", "server/out/neovim/stdio-server.js" },
			},
			agent = {
				runtime = "development",
			},
		})

		fresh_buffer()
		vim.bo.filetype = "lua"
		vim.api.nvim_buf_set_lines(0, 0, -1, false, {
			"local a = 1",
			"local b = a + 1",
		})

		commands.annotate()
		vim.wait(2000, function()
			local marks = annotations.current_marks(0)
			if #marks == 0 or not marks[1][4] or not marks[1][4].virt_lines then
				return false
			end
			local text = marks[1][4].virt_lines[1] and marks[1][4].virt_lines[1][1][1]
			return text and text:match("Development annotation") ~= nil
		end)

		local marks = annotations.current_marks(0)
		assert(#marks > 0, "expected stdio annotation marks")
		local virt_lines = marks[1][4].virt_lines
		assert(virt_lines and virt_lines[1] and virt_lines[1][1][1]:match("Development annotation"), vim.inspect(marks))
		eq(marks[1][4].virt_lines_above, true)
	end)

	annotations.clear(0)
	backend.stop()
	assert(ok, err)
end)

test("stdio backend error float shows readable message", function()
	local vantage = require("vantage")
	local commands = require("vantage.commands")
	local backend = require("vantage.backend")

	local ok, err = pcall(function()
		backend.stop()
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
      ok: false,
      error: { code: 'bad_request', message: 'Readable backend error' }
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

		commands.explain()
		vim.wait(2000, function()
			local text = last_float_text()
			return text and text:match("Readable backend error") ~= nil
		end)

		local text = last_float_text()
		assert(text ~= nil, "expected error float buffer")
		assert(text:match("Readable backend error"), text)
		assert(not text:match("table: 0x"), text)
	end)

	backend.stop()
	assert(ok, err)
end)
