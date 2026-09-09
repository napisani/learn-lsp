local root = vim.g.vantage_nvim_root

if not root or root == "" then
	local source = debug.getinfo(1, "S").source:gsub("^@", "")
	root = vim.fn.fnamemodify(source, ":p:h:h:h")
end

vim.opt.runtimepath:prepend(root)
vim.opt.packpath:prepend(root)
vim.opt.swapfile = false
vim.opt.updatecount = 0

vim.g.loaded_vantage_nvim = true

local backend = {
	mode = "development",
}
local model_name = vim.g.vantage_pi_model_name or "default"
local reasoning = vim.g.vantage_pi_reasoning
local agent = {
	runtime = "development",
	models = {
		{
			name = model_name,
			provider = vim.g.vantage_pi_provider or "openai",
			model = vim.g.vantage_pi_model or "gpt-4o-mini",
			options = {
				reasoning = reasoning,
			},
		},
	},
	default_model = model_name,
	options = {
		timeoutMs = vim.g.vantage_pi_timeout_ms,
		reasoning = reasoning,
	},
	trace = {
		prompt_path = vim.g.vantage_pi_trace_prompt_path,
		response_path = vim.g.vantage_pi_trace_response_path,
	},
}
local completion = {
	options = {
		reasoning = reasoning,
	},
}
local commands = {
	annotate = {
		waiting_message_ms = vim.g.vantage_annotation_waiting_message_ms,
		options = {
			timeoutMs = vim.g.vantage_pi_annotation_timeout_ms,
		},
	},
}

if vim.g.vantage_dev_agent == "pi" then
	backend = {
		mode = "stdio",
		command = { "node", root .. "/server/out/neovim/stdio-server.js" },
	}
	agent.runtime = "pi"
end

local function remove_empty_tables(config)
	for key, value in pairs(config) do
		if type(value) == "table" then
			remove_empty_tables(value)
			if vim.tbl_isempty(value) then
				config[key] = nil
			end
		elseif value == nil or value == "" then
			config[key] = nil
		end
	end
end

remove_empty_tables(agent)
remove_empty_tables(completion)
remove_empty_tables(commands)

require("vantage").setup({
	backend = backend,
	agent = agent,
	completion = completion,
	commands = commands,
})
