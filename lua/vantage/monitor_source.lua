-- Change detection for monitor mode, behind a seam.
--
-- This is the only module in Vantage that invokes git, which is what keeps the
-- superseded "Vantage never shells out to git" non-goal narrow: `monitor.source`
-- accepts any `fun(root): { poll = fun(cb) }`, and the git adapter below is
-- merely the shipped default.
--
-- Polling `git status` rather than watching the filesystem is deliberate. New
-- files, deletions, and gitignore filtering all come free because git already
-- computes them, and it costs no file descriptors -- a per-directory `fs_event`
-- fleet would need git anyway to seed its directory set, then reimplement
-- gitignore filtering by hand. Recursive `fs_event` would avoid the fleet but
-- does not exist on Linux, where inotify has no recursive mode.
local M = {}

---@class MonitorChange
---@field path string absolute path
---@field status string two-character porcelain code

---Splits one porcelain line into a status code and a path.
---
---Rename entries read `R  old -> new`; the new path is what changed on disk, so
---the old one is discarded. Quoted paths (produced when a name holds a special
---character) are unquoted, since every consumer treats this as a real path.
---@param line string
---@return string? status
---@return string? path
local function parse_line(line)
	if #line < 4 then
		return nil
	end
	local status = line:sub(1, 2)
	local path = line:sub(4)

	-- Only rename and copy entries carry `old -> new`. Splitting unconditionally
	-- truncated any ordinary filename that legitimately contains " -> ".
	if status:find("[RC]") then
		local _, arrow_end, renamed = path:find("%s%->%s(.+)$")
		if arrow_end then
			path = renamed
		end
	end

	if path:sub(1, 1) == '"' and path:sub(-1) == '"' then
		local ok, unquoted = pcall(function()
			return vim.fn.eval(path)
		end)
		if ok and type(unquoted) == "string" then
			path = unquoted
		end
	end

	if path == "" then
		return nil
	end
	return status, path
end

---Parses `git status --porcelain` output into changes with absolute paths.
---@param stdout string
---@param root string
---@return MonitorChange[]
function M.parse(stdout, root)
	local changes = {}
	for _, line in ipairs(vim.split(stdout or "", "\n", { plain = true })) do
		if line ~= "" then
			local status, path = parse_line(line)
			if status and path then
				table.insert(changes, { status = status, path = root .. "/" .. path })
			end
		end
	end
	return changes
end

---Git-backed source. `poll` is asynchronous: `vim.system` runs the subprocess
---off the main thread, so the ~90ms a large repository takes never stutters the
---editor the way a synchronous call on a timer would.
---
---`cb` receives `(changes, err)`. A non-nil `err` is terminal -- not a
---repository, or git absent -- and the caller stops the mode rather than
---retrying forever.
---
---`poll` returns the subprocess handle so the caller can kill a poll it has
---given up on. Without that, a `git status` wedged on an unresponsive
---filesystem would hold its pipes open for the life of the session.
---@param root string workspace root
---@return { poll: fun(cb: fun(changes: MonitorChange[]?, err: string?)): table?, first_hunk: fun(path: string, cb: fun(line: integer?)) }
function M.git(root)
	local source = {}

	function source.poll(cb)
		local ok, handle = pcall(vim.system, {
			"git",
			"status",
			"--porcelain",
			"--untracked-files=all",
		}, { cwd = root, text = true }, function(result)
			vim.schedule(function()
				if result.code ~= 0 then
					cb(nil, vim.trim(result.stderr or "") ~= "" and vim.trim(result.stderr) or "git status failed")
					return
				end
				cb(M.parse(result.stdout, root), nil)
			end)
		end)

		if not ok then
			-- git missing entirely: vim.system raises rather than returning a code.
			vim.schedule(function()
				cb(nil, tostring(handle))
			end)
			return nil
		end
		return handle
	end

	function source.first_hunk(path, cb)
		return M.first_hunk(root, path, cb)
	end

	return source
end

---First changed line in `path`, from `git diff -U0`.
---
---A capability of the source rather than a free function, so a custom
---`monitor.source` can provide its own notion of "where the change is" -- or
---omit it entirely, in which case the renderer simply gets `line = nil`.
---
---Hunk position is an enhancement, never a precondition for showing the file:
---an untracked file has no diff at all, and a failed call must degrade to
---no-line rather than suppress the entry.
---
---Returns the subprocess handle, like `poll`, so a caller that gives up on a
---render can kill the `git diff` behind it rather than leaving it holding pipes
---for the rest of the session.
---@param root string
---@param path string absolute
---@param cb fun(line: integer?)
---@return table? handle
function M.first_hunk(root, path, cb)
	local ok, handle = pcall(vim.system, {
		"git",
		"diff",
		"-U0",
		"--",
		path,
	}, { cwd = root, text = true }, function(result)
		vim.schedule(function()
			if result.code ~= 0 then
				cb(nil)
				return
			end
			-- @@ -old,count +new,count @@ -- the `+` side is the current file.
			local line = (result.stdout or ""):match("@@ %-%d+[,%d]* %+(%d+)")
			cb(line and math.max(1, tonumber(line)) or nil)
		end)
	end)

	if not ok then
		vim.schedule(function()
			cb(nil)
		end)
		return nil
	end
	return handle
end

---Test double: replays a fixed list of change-lists, one per poll, then keeps
---returning the last. Mirrors `history_store.fake` so no spec needs a real
---repository or a real subprocess.
---@param ticks MonitorChange[][]
---@return { poll: fun(cb: fun(changes: MonitorChange[]?, err: string?)) }
function M.fake(ticks)
	local queue = vim.deepcopy(ticks or {})
	local index = 0
	local source = {}

	function source.poll(cb)
		index = index + 1
		cb(queue[math.min(index, #queue)] or {}, nil)
	end

	---Test-only: how many polls have happened.
	function source._polls()
		return index
	end

	---Mirrors the git source's capability. Reports no hunk, which is the same
	---degraded path an untracked file takes.
	function source.first_hunk(_, cb)
		cb(nil)
		return { kill = function() end }
	end

	return source
end

return M
