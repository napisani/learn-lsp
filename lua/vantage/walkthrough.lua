local agent_context = require("vantage.agent_context")
local annotations = require("vantage.annotations")
local paths = require("vantage.paths")

local M = {}

local DEFAULT_PATH = ".vantage/walkthrough.json"
local AUGROUP = "vantage_walkthrough"

-- Pointers grouped by normalized absolute file path, plus the resolved
-- workspace-relative display path. Populated by M.load, consumed lazily by the
-- BufEnter autocmd and cleared by M.disarm.
local registry = {}
local armed = false

local function config()
	return require("vantage.state").config.walkthrough or {}
end

local function configured_path()
	local path = config().path
	if type(path) == "string" and path ~= "" then
		return path
	end
	return DEFAULT_PATH
end

function M.resolved_path(root)
	local path = configured_path()
	if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") then
		return paths.normalize(path)
	end
	root = root or agent_context.workspace_root()
	return paths.normalize(root .. "/" .. path)
end

-- Read and validate the walkthrough artifact. Returns a result table with a
-- status of missing | empty | invalid | loaded.
function M.read()
	local root = agent_context.workspace_root()
	local path = M.resolved_path(root)
	local result = { workspace_root = root, path = path }

	if vim.fn.filereadable(path) == 0 then
		result.status = "missing"
		return result
	end

	local content = table.concat(vim.fn.readfile(path), "\n")
	if vim.trim(content) == "" then
		result.status = "empty"
		return result
	end

	local ok, decoded = pcall(vim.json.decode, content)
	if not ok or type(decoded) ~= "table" or type(decoded.pointers) ~= "table" then
		result.status = "invalid"
		result.error = "walkthrough.json must contain a \"pointers\" array."
		return result
	end

	local pointers = {}
	for _, pointer in ipairs(decoded.pointers) do
		if type(pointer) == "table" and type(pointer.file) == "string" and pointer.file ~= "" then
			table.insert(pointers, {
				file = pointer.file,
				line = type(pointer.line) == "number" and math.max(1, math.floor(pointer.line)) or 1,
				anchor = type(pointer.anchor) == "string" and pointer.anchor or nil,
				description = type(pointer.description) == "string" and pointer.description or "",
			})
		end
	end

	result.status = "loaded"
	result.pointers = pointers
	return result
end

-- Build the annotation list (shape consumed by annotations.render) for the
-- pointers targeting a single buffer, marking entries whose anchor no longer
-- matches the line they were recorded against as [stale].
local function annotations_for_buffer(bufnr, pointers)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local built = {}
	for _, pointer in ipairs(pointers) do
		local text = pointer.description
		if pointer.anchor and pointer.line >= 1 and pointer.line <= line_count then
			local current = vim.api.nvim_buf_get_lines(bufnr, pointer.line - 1, pointer.line, false)[1] or ""
			if vim.trim(current) ~= vim.trim(pointer.anchor) then
				text = "[stale] " .. text
			end
		elseif pointer.anchor then
			text = "[stale] " .. text
		end
		table.insert(built, {
			range = { startLine = pointer.line, startCharacter = 1, endLine = pointer.line, endCharacter = 1 },
			text = text,
		})
	end
	return built
end

local function render_buffer(bufnr)
	if not vim.api.nvim_buf_is_loaded(bufnr) then
		return
	end
	local key = paths.normalize(vim.api.nvim_buf_get_name(bufnr))
	if key == "" then
		return
	end
	local entry = registry[key]
	if not entry then
		return
	end
	annotations.render(bufnr, annotations_for_buffer(bufnr, entry.pointers))
end

local function arm()
	local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
	vim.api.nvim_create_autocmd("BufEnter", {
		group = group,
		callback = function(args)
			render_buffer(args.buf)
		end,
	})
	armed = true
end

-- Drop the registry and the BufEnter hook. Existing extmarks are left to the
-- shared annotation clear so a single clear command covers both features.
function M.disarm()
	registry = {}
	if armed then
		pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
		armed = false
	end
end

-- :VantageLoadWalkthrough — read the artifact, populate the quickfix list with
-- one entry per pointer, render annotations into matching open buffers, and arm
-- lazy rendering so navigating to a pointer surfaces its annotation.
function M.load()
	local result = M.read()

	if result.status == "missing" then
		vim.notify("Vantage: no walkthrough at " .. result.path, vim.log.levels.INFO)
		return
	end
	if result.status == "empty" then
		vim.notify("Vantage: walkthrough is empty (" .. result.path .. ")", vim.log.levels.WARN)
		return
	end
	if result.status == "invalid" then
		vim.notify("Vantage: " .. (result.error or "invalid walkthrough"), vim.log.levels.ERROR)
		return
	end

	M.disarm()

	local items = {}
	for _, pointer in ipairs(result.pointers) do
		local filename = paths.resolve(result.workspace_root, pointer.file)
		local key = paths.normalize(filename)
		local entry = registry[key]
		if not entry then
			entry = { filename = filename, pointers = {} }
			registry[key] = entry
		end
		table.insert(entry.pointers, pointer)
		table.insert(items, {
			filename = filename,
			lnum = pointer.line,
			col = 1,
			text = pointer.description,
		})
	end

	vim.fn.setqflist({}, "r", {
		title = #items == 0 and "Vantage Walkthrough: no pointers" or "Vantage Walkthrough",
		items = items,
	})

	if #items == 0 then
		vim.notify("Vantage: walkthrough has no pointers", vim.log.levels.INFO)
		return
	end

	arm()

	-- Render into buffers that are already open before the user navigates.
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		render_buffer(bufnr)
	end

	vim.cmd("copen")
	vim.notify("Vantage: loaded walkthrough with " .. #items .. " pointer(s)", vim.log.levels.INFO)
end

return M
