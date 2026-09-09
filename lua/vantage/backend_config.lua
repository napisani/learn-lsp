local state = require("vantage.state")

local M = {}

local function json_object(value)
	if type(value) ~= "table" or vim.tbl_isempty(value) then
		return vim.empty_dict()
	end
	return vim.deepcopy(value)
end

local function agent_options_config(value)
	local options = json_object(value)
	-- These known Pi fields are maps; force empty maps to JSON objects while
	-- leaving every other user-provided option untouched.
	if type(options.metadata) == "table" and vim.tbl_isempty(options.metadata) then
		options.metadata = vim.empty_dict()
	end
	if type(options.headers) == "table" and vim.tbl_isempty(options.headers) then
		options.headers = vim.empty_dict()
	end
	return options
end

local function auth_config(value)
	if type(value) ~= "table" then
		return nil
	end

	local config = {}
	if value.path ~= nil then
		config.path = value.path
	end
	if vim.tbl_isempty(config) then
		return vim.empty_dict()
	end
	return config
end

local function session_output_config(value)
	value = value or {}
	return {
		history_limit = value.history_limit,
	}
end

local function agent_config(value)
	value = value or {}
	return {
		runtime = value.runtime,
		adjacent = value.adjacent and json_object(value.adjacent) or nil,
		provider = value.provider,
		model = value.model,
		auth = auth_config(value.auth),
		options = agent_options_config(value.options),
		session_output = session_output_config(value.session_output),
	}
end

local function completion_config(value)
	value = value or {}
	return {
		options = agent_options_config(value.options),
	}
end

local function command_config(value)
	value = value or {}
	return {
		include_lens = value.include_lens,
		options = agent_options_config(value.options),
	}
end

local function annotate_command_config(value)
	local config = command_config(value)
	if type(value) == "table" then
		config.waiting_message_ms = value.waiting_message_ms
	end
	return config
end

function M.request()
	local commands = state.config.commands or {}
	return {
		agent = agent_config(state.config.agent),
		completion = completion_config(state.config.completion),
		commands = {
			explain = command_config(commands.explain),
			question = command_config(commands.question),
			edit = command_config(commands.edit),
			annotate = annotate_command_config(commands.annotate),
			search = command_config(commands.search),
			walkthrough = command_config(commands.walkthrough),
		},
	}
end

return M
