local state = require("vantage.state")

local M = {}

local DEFAULT_PATH = ".vantage/agent-context.md"
local DEFAULT_MAX_BYTES = 12000
local read_cache = nil

local function trim_trailing_slash(path)
	if path == "/" then
		return path
	end
	return (path:gsub("/+$", ""))
end

local function normalize_path(path)
	return trim_trailing_slash(vim.fn.fnamemodify(path, ":p"))
end

local function path_join(root, path)
	if root == "/" then
		return "/" .. path
	end
	return root .. "/" .. path
end

local function is_absolute(path)
	return path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil
end

local function current_buffer_dir()
	local name = vim.api.nvim_buf_get_name(0)
	if name ~= "" then
		return normalize_path(vim.fn.fnamemodify(name, ":p:h"))
	end
	return normalize_path(vim.fn.getcwd())
end

local function find_workspace_root(start_dir)
	local dir = normalize_path(start_dir)

	while dir ~= "" do
		local git_path = path_join(dir, ".git")
		if vim.fn.isdirectory(git_path) == 1 or vim.fn.filereadable(git_path) == 1 then
			return dir
		end

		local parent = trim_trailing_slash(vim.fn.fnamemodify(dir, ":h"))
		if parent == dir then
			break
		end
		dir = parent
	end

	return normalize_path(vim.fn.getcwd())
end

local function config()
	return state.config.agent_context or {}
end

local function configured_path()
	local value = config().path
	if type(value) == "string" and value ~= "" then
		return value
	end
	return DEFAULT_PATH
end

local function max_bytes()
	local value = config().max_bytes
	if type(value) == "number" and value > 0 and math.floor(value) == value then
		return value
	end
	return DEFAULT_MAX_BYTES
end

local function max_age_ms()
	local value = config().max_age_ms
	if type(value) == "number" and value >= 0 then
		return value
	end
	return nil
end

local function iso_timestamp(stat)
	if not stat or not stat.mtime or not stat.mtime.sec then
		return nil
	end

	local millis = math.floor((stat.mtime.nsec or 0) / 1000000)
	return os.date("!%Y-%m-%dT%H:%M:%S", stat.mtime.sec) .. string.format(".%03dZ", millis)
end

local function age_ms(stat)
	if not stat or not stat.mtime or not stat.mtime.sec then
		return nil
	end

	local mtime_ms = (stat.mtime.sec * 1000) + math.floor((stat.mtime.nsec or 0) / 1000000)
	local now_ms = os.time() * 1000
	return math.max(0, now_ms - mtime_ms)
end

local function stat_revision(path, stat, limit)
	local mtime = stat and stat.mtime or {}
	return table.concat({
		path,
		tostring(stat and stat.size or 0),
		tostring(limit),
		tostring(mtime.sec or 0),
		tostring(mtime.nsec or 0),
	}, ":")
end

local function cache_matches(path, stat, limit)
	if not read_cache then
		return false
	end
	local mtime = stat.mtime or {}
	return read_cache.path == path
		and read_cache.size == stat.size
		and read_cache.limit == limit
		and read_cache.mtime_sec == mtime.sec
		and read_cache.mtime_nsec == mtime.nsec
end

local function read_tail(path, size, limit)
	local offset = math.max(0, size - limit)
	local length = size - offset
	local fd, open_err = vim.loop.fs_open(path, "r", 438)
	if not fd then
		return nil, open_err or "failed to open file"
	end

	local data, read_err = vim.loop.fs_read(fd, length, offset)
	vim.loop.fs_close(fd)
	if not data then
		return nil, read_err or "failed to read file"
	end

	return data, nil
end

function M.workspace_root()
	return find_workspace_root(current_buffer_dir())
end

function M.resolved_path(root)
	local path = configured_path()
	if is_absolute(path) then
		return normalize_path(path)
	end
	return normalize_path(path_join(root or M.workspace_root(), path))
end

function M.snapshot()
	local root = M.workspace_root()
	local path = M.resolved_path(root)
	local enabled = config().enabled ~= false
	local result = {
		enabled = enabled,
		workspace_root = root,
		path = path,
		context = nil,
	}

	if not enabled then
		result.status = "disabled"
		return result
	end

	local stat = vim.loop.fs_stat(path)
	if not stat then
		result.status = "missing"
		result.exists = false
		return result
	end

	result.exists = true
	result.size_bytes = stat.size or 0
	result.modified_at = iso_timestamp(stat)
	result.age_ms = age_ms(stat)

	if stat.type ~= "file" then
		result.status = "unavailable"
		result.error = "Agent Context File is not a file."
		return result
	end

	if result.size_bytes == 0 then
		result.status = "empty"
		result.included_bytes = 0
		result.truncated = false
		return result
	end

	local age_limit = max_age_ms()
	if age_limit and result.age_ms and result.age_ms > age_limit then
		result.status = "stale"
		return result
	end

	local limit = max_bytes()
	local content
	if cache_matches(path, stat, limit) then
		content = read_cache.content
	else
		local read_err
		content, read_err = read_tail(path, result.size_bytes, limit)
		if not content then
			result.status = "unavailable"
			result.error = read_err
			return result
		end

		local mtime = stat.mtime or {}
		read_cache = {
			path = path,
			size = stat.size,
			limit = limit,
			mtime_sec = mtime.sec,
			mtime_nsec = mtime.nsec,
			content = content,
		}
	end

	result.status = "included"
	result.included_bytes = #content
	result.truncated = result.size_bytes > limit
	result.revision = stat_revision(path, stat, limit)
	result.context = {
		path = path,
		content = content,
		revision = result.revision,
		modifiedAt = result.modified_at,
		ageMs = result.age_ms,
		truncated = result.truncated,
	}
	return result
end

return M
