local M = {}

local artifact = {
	cases = {},
	commands = {},
}

local suite = {
	root = nil,
	workspace = nil,
	calculator = nil,
	target_buf = nil,
	initial_calculator = nil,
}

local function repo_root()
	local root = vim.g.vantage_nvim_root
	if root and root ~= "" then
		return root
	end
	return vim.fn.fnamemodify(debug.getinfo(1, "S").source:gsub("^@", ""), ":p:h:h:h")
end

local function artifact_path()
	return vim.g.vantage_e2e_artifact_path or (repo_root() .. "/.nvim-dev/e2e/model-all-commands.json")
end

local function write_artifact()
	local path = artifact_path()
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	vim.fn.writefile({ vim.json.encode(artifact) }, path)
	return path
end

local function fail(message)
	artifact.failure = message
	artifact.finalBuffer = suite.target_buf
			and vim.api.nvim_buf_is_valid(suite.target_buf)
			and vim.api.nvim_buf_get_lines(suite.target_buf, 0, -1, false)
		or nil
	artifact.finalQuickfix = vim.fn.getqflist()
	artifact.finalLens = require("vantage").get_lens()
	local path = write_artifact()
	vim.api.nvim_err_writeln(message .. "; artifact: " .. path)
	vim.cmd("silent! bufdo setlocal nomodified")
	vim.cmd("cquit")
end

local function wait_ms()
	return tonumber(vim.g.vantage_e2e_wait_ms or "") or 120000
end

local function close_floats()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_config(win).relative ~= "" then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end
end

local function float_text()
	local buf = require("vantage.ui").last_float_buf()
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return nil
	end
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function assert_no_error(name)
	local text = float_text()
	if text and text:match("^## Error") then
		fail(name .. " produced an error surface: " .. text)
	end
end

local function focus_target()
	if suite.target_buf and vim.api.nvim_buf_is_valid(suite.target_buf) then
		local win = vim.api.nvim_get_current_win()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_set_buf(win, suite.target_buf)
		end
		vim.api.nvim_set_current_buf(suite.target_buf)
	end
end

local function command_entry(case_entry, command)
	local entry = {
		case = case_entry.name,
		command = command,
		status = "running",
	}
	table.insert(artifact.commands, entry)
	write_artifact()
	return entry
end

local function run_command(case_entry, command, opts)
	opts = opts or {}
	if opts.close_floats ~= false then
		close_floats()
	end
	if opts.focus_target ~= false then
		focus_target()
	end
	local entry = command_entry(case_entry, command)
	local ok, err = pcall(vim.cmd, command)
	if not ok then
		entry.status = "failed"
		entry.error = tostring(err)
		fail(case_entry.name .. " failed immediately: " .. tostring(err))
	end
	entry.status = "ok"
	write_artifact()
	return entry
end

local function wait_for_float(case_entry)
	local ready = vim.wait(wait_ms(), function()
		local text = float_text()
		return text and text ~= ""
	end, 100)
	if not ready then
		fail(case_entry.name .. " did not produce an output surface")
	end
	assert_no_error(case_entry.name)
	return float_text()
end

local function wait_for_tracked_request(case_entry, before_updated_at)
	local tracker = require("vantage.request_tracker")
	local completed = vim.wait(wait_ms(), function()
		local status = tracker.status()
		return status.updated_at ~= before_updated_at and status.status ~= "loading"
	end, 100)
	if not completed then
		fail(case_entry.name .. " did not finish its tracked request")
	end
	local status = tracker.status()
	if status.status == "failed" or status.status == "cancelled" then
		fail(case_entry.name .. " failed: " .. tostring(status.error or status.message))
	end
	assert_no_error(case_entry.name)
	return status
end

local function tracked_command(case_entry, command)
	local before = require("vantage.request_tracker").status().updated_at
	local entry = run_command(case_entry, command)
	entry.request = wait_for_tracked_request(case_entry, before)
	entry.floatText = float_text()
	write_artifact()
	return entry
end

local function terminal_float_command(case_entry, command)
	local entry = run_command(case_entry, command)
	entry.floatText = wait_for_float(case_entry)
	write_artifact()
	return entry
end

local function prompt_buffer()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if require("vantage.ui.prompt_buffer").is_prompt_buffer(buf) then
			return buf
		end
	end
	return nil
end

local function submit_prompt(case_entry, text)
	local buf = vim.wait(5000, function()
		return prompt_buffer() ~= nil
	end, 25) and prompt_buffer() or nil
	if not buf then
		fail(case_entry.name .. " did not open a prompt buffer")
	end
	local win = require("vantage.ui").last_float_win()
	if not win or not vim.api.nvim_win_is_valid(win) then
		fail(case_entry.name .. " prompt window is unavailable")
	end
	vim.api.nvim_set_current_win(win)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
end

local function tracked_prompt_command(case_entry, command, text)
	local before = require("vantage.request_tracker").status().updated_at
	run_command(case_entry, command)
	submit_prompt(case_entry, text)
	local entry = artifact.commands[#artifact.commands]
	entry.request = wait_for_tracked_request(case_entry, before)
	entry.floatText = float_text()
	write_artifact()
	return entry
end

local function set_cursor_to(text)
	local lines = vim.api.nvim_buf_get_lines(suite.target_buf, 0, -1, false)
	for index, line in ipairs(lines) do
		if line:find(text, 1, true) then
			focus_target()
			vim.api.nvim_win_set_cursor(0, { index, 0 })
			return index
		end
	end
	fail("fixture line was not found: " .. text)
end

local function set_visual_selection()
	focus_target()
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	vim.cmd("normal! Vj")
	-- Leaving visual mode stamps '< and '> so the following Ex command takes
	-- the same range a user just selected.
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
end

local function restore_calculator()
	focus_target()
	vim.bo[suite.target_buf].modifiable = true
	vim.api.nvim_buf_set_lines(suite.target_buf, 0, -1, false, suite.initial_calculator)
	vim.cmd("silent write!")
	vim.bo[suite.target_buf].modified = false
end

local function output_is_regular_window()
	local win = require("vantage.ui").last_float_win()
	return win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative == ""
end

local function case(name, command_name, run)
	return { name = name, commandName = command_name, run = run }
end

local cases = {
	case("lens:set-explicit", "VantageSetLens", function(current)
		run_command(current, "VantageSetLens learning Keep answers concise")
		local lens = require("vantage").get_lens()
		if not lens or lens.mode ~= "learning" then
			fail("VantageSetLens did not set a lens")
		end
	end),
	case("lens:set-prompt", "VantageSetLens", function(current)
		local original = vim.ui.input
		vim.ui.input = function(_, callback)
			callback("Prompted lens")
		end
		run_command(current, "VantageSetLens review")
		vim.ui.input = original
		local lens = require("vantage").get_lens()
		if not lens or lens.text ~= "Prompted lens" then
			fail("prompted VantageSetLens did not set the supplied text")
		end
	end),
	case("explain:agent-line", "VantageExplain", function(current)
		set_cursor_to("local total = value + bonus")
		tracked_command(current, "VantageExplain runtime=agent")
		wait_for_float(current)
	end),
	case("explain:completion-range", "VantageExplain", function(current)
		tracked_command(current, "2,4VantageExplain runtime=completion")
		wait_for_float(current)
	end),
	case("question:agent-inline", "VantageQuestion", function(current)
		tracked_command(current, "VantageQuestion runtime=agent What does this helper return?")
		wait_for_float(current)
	end),
	case("question:completion-visual", "VantageQuestion", function(current)
		set_visual_selection()
		tracked_command(current, "'<,'>VantageQuestion runtime=completion What is selected here?")
		wait_for_float(current)
	end),
	case("question:prompt-buffer", "VantageQuestion", function(current)
		tracked_prompt_command(current, "VantageQuestion runtime=agent", "Give a one sentence description.")
		wait_for_float(current)
	end),
	case("edit:agent", "VantageEdit", function(current)
		set_cursor_to("local total = value + bonus")
		tracked_command(current, "VantageEdit runtime=agent Rename only local total to local computed")
		restore_calculator()
	end),
	case("edit:completion", "VantageEdit", function(current)
		set_visual_selection()
		tracked_command(current, "'<,'>VantageEdit runtime=completion Add a harmless comment to this selection")
		restore_calculator()
	end),
	case("annotate:agent-buffer-max", "VantageAnnotate", function(current)
		tracked_command(current, "VantageAnnotate runtime=agent buffer 2")
	end),
	case("annotate:completion-line", "VantageAnnotate", function(current)
		set_cursor_to("local M = {}")
		tracked_command(current, "VantageAnnotate runtime=completion line 1")
	end),
	case("annotation:clear", "VantageAnnotationClear", function(current)
		run_command(current, "VantageAnnotationClear")
		if #require("vantage.annotations").current_marks(suite.target_buf) ~= 0 then
			fail("VantageAnnotationClear left annotations behind")
		end
	end),
	case("search:inline", "VantageSearch", function(current)
		-- Start this structured-tool request on a fresh session. A model may retain
		-- a prior command's response format even though Vantage updates active tools.
		terminal_float_command(current, "VantageAgentReset")
		local success = false
		for attempt = 1, 3 do
			vim.fn.setqflist({}, "r", { title = "" })
			local entry = run_command(
				current,
				"VantageSearch Find the calculator.total_score(items) call in lua/report.lua. Call submit_search_results exactly once with that location; do not respond with prose."
			)
			entry.attempt = attempt
			local ready = vim.wait(wait_ms(), function()
				return (vim.fn.getqflist({ title = 1 }).title or ""):match("^Vantage Search") ~= nil
					or (float_text() or ""):match("^## Error") ~= nil
			end, 100)
			if ready and (vim.fn.getqflist({ title = 1 }).title or ""):match("^Vantage Search") then
				success = true
				entry.quickfixCount = #vim.fn.getqflist()
				break
			end
			entry.status = "retry"
			entry.floatText = float_text()
			write_artifact()
		end
		if not success then
			fail("VantageSearch did not submit results after three attempts")
		end
		artifact.quickfix = vim.fn.getqflist()
		vim.cmd("cclose")
	end),
	case("walkthrough:generate", "VantageGenerateWalkthrough", function(current)
		terminal_float_command(current, "VantageAgentReset")
		local path = suite.workspace .. "/.vantage/walkthrough.json"
		vim.fn.delete(path)
		local success = false
		for attempt = 1, 3 do
			local entry = run_command(
				current,
				"VantageGenerateWalkthrough Give one pointer to calculator.lua. Call submit_walkthrough exactly once; do not respond with prose."
			)
			entry.attempt = attempt
			local ready = vim.wait(wait_ms(), function()
				return vim.fn.filereadable(path) == 1 or (float_text() or ""):match("^## Error") ~= nil
			end, 100)
			if ready and vim.fn.filereadable(path) == 1 then
				success = true
				break
			end
			entry.status = "retry"
			entry.floatText = float_text()
			write_artifact()
		end
		if not success then
			fail("VantageGenerateWalkthrough did not write a walkthrough after three attempts")
		end
		artifact.walkthroughPath = path
		vim.cmd("cclose")
	end),
	case("walkthrough:load", "VantageLoadWalkthrough", function(current)
		run_command(current, "VantageLoadWalkthrough")
		if (vim.fn.getqflist({ title = 1 }).title or ""):match("^Vantage Walkthrough") == nil then
			fail("VantageLoadWalkthrough did not load the generated walkthrough")
		end
		vim.cmd("cclose")
	end),
	case("status", "VantageStatus", function(current)
		local entry = terminal_float_command(current, "VantageStatus")
		if not entry.floatText:match("### Agent Session") then
			fail("VantageStatus did not include agent session state")
		end
	end),
	case("session-output", "VantageSessionOutput", function(current)
		local entry = terminal_float_command(current, "VantageSessionOutput")
		local loaded = vim.wait(5000, function()
			entry.floatText = float_text()
			return entry.floatText and entry.floatText:match("Vantage Session Output") ~= nil
		end, 100)
		if not loaded then
			fail("VantageSessionOutput did not load its session history")
		end
		write_artifact()
	end),
	case("model:named", "VantageModel", function(current)
		terminal_float_command(current, "VantageModel default")
	end),
	case("output:split", "VantageOutputToBuffer", function(current)
		terminal_float_command(current, "VantageStatus")
		run_command(current, "VantageOutputToBuffer", { close_floats = false, focus_target = false })
		if not output_is_regular_window() then
			fail("VantageOutputToBuffer did not promote output to a split")
		end
		vim.api.nvim_win_close(require("vantage.ui").last_float_win(), true)
	end),
	case("output:vsplit", "VantageOutputToBuffer", function(current)
		terminal_float_command(current, "VantageStatus")
		run_command(current, "VantageOutputToBuffer vsplit", { close_floats = false, focus_target = false })
		if not output_is_regular_window() then
			fail("VantageOutputToBuffer vsplit did not promote output")
		end
		vim.api.nvim_win_close(require("vantage.ui").last_float_win(), true)
	end),
	case("compose:open", "VantageCompose", function(current)
		run_command(current, "VantageCompose")
		local buf = require("vantage.composition").get_bufnr()
		if not buf then
			fail("VantageCompose did not create a composition buffer")
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Briefly describe this calculator." })
	end),
	case("compose:send", "VantageComposeSend", function(current)
		local before = require("vantage.request_tracker").status().updated_at
		run_command(current, "VantageComposeSend", { focus_target = false })
		wait_for_tracked_request(current, before)
		wait_for_float(current)
	end),
	case("compose:clear", "VantageComposeClear", function(current)
		run_command(current, "VantageCompose")
		local buf = require("vantage.composition").get_bufnr()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Discard this staged text." })
		run_command(current, "VantageComposeClear", { focus_target = false })
		if not require("vantage.composition").is_empty() then
			fail("VantageComposeClear did not empty staged text")
		end
		require("vantage.composition").close()
	end),
	case("history:pick", "VantageHistory", function(current)
		focus_target()
		vim.fn.setreg("", "")
		local original = vim.ui.select
		vim.ui.select = function(items, _, callback)
			callback(items[1], 1)
		end
		run_command(current, "VantageHistory")
		vim.ui.select = original
		if vim.fn.getreg("") == "" then
			fail("VantageHistory did not select a recorded prompt")
		end
	end),
	case("history:clear-workspace", "VantageHistoryClearWorkspace", function(current)
		run_command(current, "VantageHistoryClearWorkspace")
		local workspace = suite.workspace
		if #require("vantage.history").entries({ workspace = workspace }) ~= 0 then
			fail("VantageHistoryClearWorkspace left workspace entries behind")
		end
	end),
	case("history:clear-all", "VantageHistoryClearAll", function(current)
		run_command(current, "VantageHistoryClearAll")
		if #require("vantage.history").entries() ~= 0 then
			fail("VantageHistoryClearAll left entries behind")
		end
	end),
	case("monitor:start-change-stop", "VantageMonitor", function(current)
		run_command(current, "VantageMonitor")
		if not require("vantage.monitor").is_active() then
			fail("VantageMonitor did not start")
		end
		local seeded = vim.wait(10000, function()
			return require("vantage.monitor").health().seeded
		end, 100)
		if not seeded then
			fail("VantageMonitor did not establish its workspace baseline")
		end
		vim.fn.writefile({ "-- changed by the Vantage E2E monitor case" }, suite.workspace .. "/lua/monitor_probe.lua")
		local observed = vim.wait(10000, function()
			return #require("vantage.monitor").entries() > 0
		end, 100)
		if not observed then
			fail("VantageMonitor did not observe an external workspace change")
		end
		run_command(current, "VantageMonitor")
		if require("vantage.monitor").is_active() then
			fail("VantageMonitor did not stop")
		end
	end),
	case("debug-log", "VantageDebugLog", function(current)
		local path = (require("vantage.state").config.debug or {}).log_path
		if not path then
			fail("E2E debug log path is not configured")
		end
		vim.fn.writefile({ '{"event":"e2e"}' }, path)
		terminal_float_command(current, "VantageDebugLog")
	end),
	case("health", "VantageHealth", function(current)
		run_command(current, "VantageHealth")
		local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
		if not table.concat(lines, "\n"):lower():match("vantage") then
			fail("VantageHealth did not open Vantage health output")
		end
	end),
	case("cancel:idle", "VantageCancel", function(current)
		terminal_float_command(current, "VantageCancel")
	end),
	case("agent-reset", "VantageAgentReset", function(current)
		terminal_float_command(current, "VantageAgentReset")
	end),
	case("lens:clear", "VantageClearLens", function(current)
		run_command(current, "VantageClearLens")
		if require("vantage").get_lens() ~= nil then
			fail("VantageClearLens did not clear the active lens")
		end
	end),
}

local function assert_command_coverage()
	local required = {}
	for _, name in ipairs(require("vantage.command_names").all) do
		required[name] = true
	end
	local covered = {}
	for _, entry in ipairs(cases) do
		covered[entry.commandName] = true
	end
	for name in pairs(required) do
		if not covered[name] then
			fail("missing E2E case for registered command " .. name)
		end
	end
	for name in pairs(covered) do
		if not required[name] then
			fail("E2E case references stale command " .. name)
		end
	end
	artifact.coverage = { required = vim.tbl_keys(required), covered = vim.tbl_keys(covered) }
end

local function setup_fixture()
	suite.root = repo_root()
	suite.workspace = vim.g.vantage_e2e_codebase_path or (suite.root .. "/examples/e2e-codebase")
	suite.calculator = suite.workspace .. "/lua/calculator.lua"
	vim.cmd("cd " .. vim.fn.fnameescape(suite.workspace))
	vim.cmd("edit " .. vim.fn.fnameescape(suite.calculator))
	vim.bo.filetype = "lua"
	suite.target_buf = vim.api.nvim_get_current_buf()
	suite.initial_calculator = vim.api.nvim_buf_get_lines(suite.target_buf, 0, -1, false)
	artifact.cwd = vim.fn.getcwd()
	artifact.workspace = suite.workspace
	artifact.openedFile = vim.api.nvim_buf_get_name(suite.target_buf)
	artifact.model = {
		provider = vim.g.vantage_pi_provider,
		model = vim.g.vantage_pi_model,
		reasoning = vim.g.vantage_pi_reasoning,
	}
	artifact.backend = require("vantage.state").config.backend
	write_artifact()
end

function M.run()
	setup_fixture()
	assert_command_coverage()
	for _, current in ipairs(cases) do
		local result = { name = current.name, commandName = current.commandName, status = "running" }
		table.insert(artifact.cases, result)
		write_artifact()
		current.run(current)
		result.status = "ok"
		result.floatText = float_text()
		write_artifact()
	end
	artifact.status = "ok"
	artifact.finalBuffer = vim.api.nvim_buf_get_lines(suite.target_buf, 0, -1, false)
	artifact.finalLens = require("vantage").get_lens()
	write_artifact()
	vim.cmd("silent! bufdo setlocal nomodified")
end

return M
