-- Persistence for prompt history: an append-only NDJSON file.
--
-- Append-only rather than rewrite-the-array because several nvim instances share
-- one user-global file. Appending lets concurrent writers interleave instead of
-- clobbering each other; a rewrite happens only at load time, and only once the
-- file has grown well past the retention cap.
--
-- Same format and write mode as `debug.log_path` in backend.lua, but a stricter
-- file mode: that log is opt-in and nil by default, whereas this file holds
-- prompt text by default and so is created 0600 like shada and shell history.
local M = {}

---How many times the retention cap a file may reach before load() compacts it.
---Generous on purpose: compaction is last-writer-wins across instances, so
---rewriting rarely costs less than it risks.
local COMPACTION_FACTOR = 4

---Schema version stamped on every appended row. Present so a future field
---rename can migrate old rows instead of silently reading them as nil -- an
---entry with a nil workspaceRoot would be invisible to cycling *and* skipped by
---a workspace-scoped purge, leaving prompt text on disk.
local SCHEMA_VERSION = 1

-- 0600 / 0700: prompt text and abandoned drafts must not be world-readable.
local FILE_MODE = 384
local DIR_MODE = "0700"

---@class HistoryStore
---@field load fun(): table[], integer, boolean entries oldest-first, skipped-line count, read_failed
---@field append fun(entry: table): boolean, string?
---@field rewrite fun(entries: table[]): boolean, string?

---Whether a file of `line_count` lines justifies a compacting rewrite.
---
---Module-level rather than per-store: it is pure policy over its arguments and
---touches no store state, so making every implementation carry a copy only
---created two places for the rule to drift.
---@param line_count integer total non-empty lines on disk, including unreadable ones
---@param limit integer retention cap
---@return boolean
function M.should_compact(line_count, limit)
	return line_count > limit * COMPACTION_FACTOR
end

---Coerces a decoded row into a well-formed entry, applying the same defaults
---`history.record` applies to new ones.
---
---Normalizing here rather than trusting the file keeps the ring's invariants
---true regardless of how old or hand-edited a row is. Without it a row whose
---`workspaceRoot` is not a string reaches `dedup_key` and raises, aborting the
---load mid-file.
---@param decoded any
---@return table? entry nil when the row cannot be salvaged
local function normalize(decoded)
	if type(decoded) ~= "table" or type(decoded.text) ~= "string" or decoded.text == "" then
		return nil
	end

	return {
		kind = type(decoded.kind) == "string" and decoded.kind or "prompt",
		text = decoded.text,
		timestamp = type(decoded.timestamp) == "number" and decoded.timestamp or 0,
		workspaceRoot = type(decoded.workspaceRoot) == "string" and decoded.workspaceRoot or "",
		filePath = type(decoded.filePath) == "string" and decoded.filePath or nil,
		submitted = decoded.submitted ~= false,
	}
end

---Creates the containing directory if needed. `vim.fn.mkdir` raises (E739) when
---the path is blocked -- by an existing file, for instance -- so it is guarded:
---a bad path must surface as a reported failure, never as an error escaping into
---a submit.
---@param path string
---@return boolean ok
---@return string? err
local function ensure_parent(path)
	local dir = vim.fn.fnamemodify(path, ":h")
	if dir == "" or vim.fn.isdirectory(dir) == 1 then
		return true
	end
	local ok, err = pcall(vim.fn.mkdir, dir, "p", DIR_MODE)
	if not ok then
		return false, tostring(err)
	end
	return true
end

---Writes `data` in full, treating a short write as failure.
---@param fd integer
---@param data string
---@return boolean ok
---@return string? err
local function write_all(fd, data)
	local written = vim.loop.fs_write(fd, data, -1)
	if type(written) ~= "number" or written ~= #data then
		return false, "short write (" .. tostring(written) .. " of " .. #data .. " bytes)"
	end
	return true
end

---File-backed store. `path` is resolved once by the caller from config.
---@param path string
---@return HistoryStore
function M.ndjson(path)
	local store = { should_compact = M.should_compact }

	---Reads every line, normalizing what it can and counting what it cannot.
	---
	---The third return distinguishes "the file is empty" from "the file could
	---not be read": collapsing those made a transient read error look like no
	---history at all, after which a rewrite would persist that emptiness.
	---@return table[] entries oldest-first
	---@return integer skipped unreadable lines
	---@return boolean read_failed
	---@return integer line_count total non-empty lines seen
	function store.load()
		local fd, open_err = vim.loop.fs_open(path, "r", 438)
		if not fd then
			-- A missing file is the normal first-run case; anything else is a
			-- real failure the caller must not mistake for emptiness.
			local missing = tostring(open_err or ""):match("^ENOENT") ~= nil
			return {}, 0, not missing, 0
		end

		local stat = vim.loop.fs_fstat(fd)
		local content = nil
		if stat and stat.size > 0 then
			content = vim.loop.fs_read(fd, stat.size, 0)
		elseif stat then
			content = ""
		end
		vim.loop.fs_close(fd)

		if content == nil then
			return {}, 0, true, 0
		end

		local entries = {}
		local skipped = 0
		local line_count = 0
		for _, line in ipairs(vim.split(content, "\n", { plain = true })) do
			if line ~= "" then
				line_count = line_count + 1
				local ok, decoded = pcall(vim.json.decode, line)
				local entry = ok and normalize(decoded) or nil
				if entry then
					table.insert(entries, entry)
				else
					skipped = skipped + 1
				end
			end
		end
		return entries, skipped, false, line_count
	end

	---@param entry table
	---@return boolean ok
	---@return string? err
	function store.append(entry)
		local payload = vim.tbl_extend("keep", { v = SCHEMA_VERSION }, entry)
		local encoded_ok, encoded = pcall(vim.json.encode, payload)
		if not encoded_ok then
			return false, "could not encode history entry"
		end

		local dir_ok, dir_err = ensure_parent(path)
		if not dir_ok then
			return false, dir_err
		end
		local fd, open_err = vim.loop.fs_open(path, "a", FILE_MODE)
		if not fd then
			return false, tostring(open_err)
		end
		local ok, err = write_all(fd, encoded .. "\n")
		vim.loop.fs_close(fd)
		return ok, err
	end

	---Replaces the file wholesale. Used by compaction and by the clear commands.
	---
	---Writes to a sibling temp file and renames, so a failed or partial write
	---cannot leave the real file truncated -- `"w"` on the live path would
	---destroy the history before knowing whether the replacement could be
	---written.
	---@param entries table[] oldest-first
	---@return boolean ok
	---@return string? err
	function store.rewrite(entries)
		local dir_ok, dir_err = ensure_parent(path)
		if not dir_ok then
			return false, dir_err
		end

		local lines = {}
		for _, entry in ipairs(entries) do
			local ok, encoded = pcall(vim.json.encode, vim.tbl_extend("keep", { v = SCHEMA_VERSION }, entry))
			if ok then
				table.insert(lines, encoded)
			end
		end

		local temp = path .. ".tmp"
		local fd, open_err = vim.loop.fs_open(temp, "w", FILE_MODE)
		if not fd then
			return false, tostring(open_err)
		end

		local body = #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""
		local wrote, write_err = true, nil
		if body ~= "" then
			wrote, write_err = write_all(fd, body)
		end
		vim.loop.fs_close(fd)

		if not wrote then
			pcall(vim.loop.fs_unlink, temp)
			return false, write_err
		end

		local renamed, rename_err = vim.loop.fs_rename(temp, path)
		if not renamed then
			pcall(vim.loop.fs_unlink, temp)
			return false, tostring(rename_err)
		end
		return true
	end

	return store
end

---Non-persistent store for tests: same contract, backed by a table instead of
---a file.
---@param seed table[]?
---@return HistoryStore
function M.fake(seed)
	local lines = vim.deepcopy(seed or {})
	local store = { should_compact = M.should_compact }

	function store.load()
		local entries = {}
		local skipped = 0
		for _, row in ipairs(lines) do
			local entry = normalize(row)
			if entry then
				table.insert(entries, entry)
			else
				skipped = skipped + 1
			end
		end
		return entries, skipped, false, #lines
	end

	function store.append(entry)
		table.insert(lines, vim.deepcopy(entry))
		return true
	end

	function store.rewrite(entries)
		lines = vim.deepcopy(entries)
		return true
	end

	---Test-only view of what would be on disk.
	function store._lines()
		return lines
	end

	return store
end

return M
