-- Prompt history: a capped, deduped ring of prompts the user submitted (or
-- abandoned), plus the cursor arithmetic for cycling it.
--
-- Deliberately knows nothing about buffers, windows, or keymaps -- that is
-- `ui/history_keymap.lua`'s job. Storage is behind a seam so the ring is
-- testable without touching the user's real state directory.
local state = require("vantage.state")
local history_store = require("vantage.history_store")

local M = {}

---@class HistoryEntry
---@field kind string question|edit|search|walkthrough|annotate|prompt|composition
---@field text string raw typed text, never reference-expanded
---@field timestamp integer os.time()
---@field workspaceRoot string cycling filter key
---@field filePath string? absent for composition, which spans files
---@field submitted boolean false = abandoned draft captured on close

---@class CycleState
---@field index integer? nil = at newest (not cycling); 1 = newest entry
---@field draft string? buffer content when cycling began

---@type HistoryEntry[] newest-first, the cycling source of truth
local ring = {}

---@type HistoryStore|nil
local store = nil

local loaded = false

-- Each distinct failure notifies once per session; a broken state dir must not
-- produce a notification storm on every keystroke.
local warned = {}

local function warn_once(key, message)
	if warned[key] then
		return
	end
	warned[key] = true
	vim.notify("Vantage history: " .. message, vim.log.levels.WARN)
end

local function config()
	return state.config.history or {}
end

---Whether history is on. Public because the cycle keymaps must not be bound
---when it is off -- gating only `record` left the documented kill switch
---binding <Up>/<Down> and reading the store anyway.
---@return boolean
function M.enabled()
	return config().enabled ~= false
end

-- Defaults live in state.default_config(); nothing is restated here so there is
-- one source of truth for the cap and the entry-size ceiling.
local function limit()
	return config().limit
end

local function current_store()
	if not store then
		store = history_store.ndjson(config().path)
	end
	return store
end

---Dedup key. Two entries collide when the same text was used in the same
---workspace, regardless of which command produced it -- recalling a prompt does
---not care whether it was originally a question or an edit.
local function dedup_key(entry)
	return (entry.workspaceRoot or "") .. "\0" .. entry.text
end

---Inserts newest-first, collapsing any existing duplicate, then applies the cap.
---A real send supersedes an abandoned draft of the same text.
local function insert_entry(entry)
	local key = dedup_key(entry)
	for index, existing in ipairs(ring) do
		if dedup_key(existing) == key then
			if existing.submitted then
				entry.submitted = true
			end
			table.remove(ring, index)
			break
		end
	end

	table.insert(ring, 1, entry)
	while #ring > limit() do
		table.remove(ring)
	end
end

---The ring as the store wants it: oldest-first.
---@return HistoryEntry[]
local function oldest_first()
	local reversed = {}
	for index = #ring, 1, -1 do
		table.insert(reversed, ring[index])
	end
	return reversed
end

---Reports a failed write once. `rewrite`/`append` signal failure by *returning*
---false, so a bare pcall around them reports success for a write that never
---touched disk.
---@param key string
---@param call fun(): boolean, string?
---@return boolean ok
local function attempt_write(key, call)
	local pok, wrote, err = pcall(call)
	if not pok then
		warn_once(key, "history file write raised (" .. tostring(wrote) .. ")")
		return false
	end
	if wrote == false then
		warn_once(key, "could not write history file (" .. tostring(err) .. ")")
		return false
	end
	return true
end

---Loads from the store once per session, compacting the file if it has grown
---well past the cap.
local function ensure_loaded()
	if loaded then
		return
	end

	local pok, entries, skipped, read_failed, line_count = pcall(current_store().load)
	if not pok then
		warn_once("load", "could not read history file")
		return
	end
	if read_failed then
		-- Leave `loaded` false so a transient failure can be retried, and so no
		-- rewrite can persist an emptiness that was never on disk.
		warn_once("load", "could not read history file; history is unavailable this session")
		return
	end

	loaded = true

	-- load() returns oldest-first; insert in that order so newest ends up first.
	for _, entry in ipairs(entries) do
		insert_entry(entry)
	end

	if skipped and skipped > 0 then
		warn_once("corrupt", skipped .. " unreadable entr" .. (skipped == 1 and "y" or "ies") .. " skipped")
	end

	-- Counted from lines on disk, not decoded entries: a file of mostly
	-- unreadable lines would otherwise never reach the threshold and so never
	-- get pruned.
	if current_store().should_compact(line_count or #entries, limit()) then
		attempt_write("compact", function()
			return current_store().rewrite(oldest_first())
		end)
	end
end

---Records a prompt. Never raises: history is a convenience and must not be able
---to break a submit.
---@param entry HistoryEntry
---@return boolean recorded
function M.record(entry)
	if not M.enabled() then
		return false
	end
	if type(entry) ~= "table" or type(entry.text) ~= "string" or vim.trim(entry.text) == "" then
		return false
	end

	local max_bytes = config().max_entry_bytes
	if #entry.text > max_bytes then
		-- Skipped rather than truncated, so a stored entry is always byte-exact.
		warn_once("oversize", "entry over " .. max_bytes .. " bytes was not recorded")
		return false
	end

	ensure_loaded()

	local recorded = {
		kind = entry.kind or "prompt",
		text = entry.text,
		timestamp = entry.timestamp or os.time(),
		workspaceRoot = entry.workspaceRoot or "",
		filePath = entry.filePath,
		submitted = entry.submitted ~= false,
	}
	insert_entry(recorded)

	-- The ring still has it either way, so cycling works for this session.
	attempt_write("append", function()
		return current_store().append(recorded)
	end)
	return true
end

---Newest-first entries, optionally filtered to one workspace.
---@param opts { workspace?: string }?
---@return HistoryEntry[]
function M.entries(opts)
	opts = opts or {}
	ensure_loaded()

	if not opts.workspace then
		return vim.deepcopy(ring)
	end

	local filtered = {}
	for _, entry in ipairs(ring) do
		if entry.workspaceRoot == opts.workspace then
			table.insert(filtered, vim.deepcopy(entry))
		end
	end
	return filtered
end

---Pure cursor arithmetic over the ring.
---
---Returns the text to display and the next cycle state. `text` is nil when
---there is nowhere to move, in which case the caller leaves the buffer alone.
---Cycling past newest restores `state.draft`; there is no wrap-around at either
---end, so holding a key cannot loop you back around unexpectedly.
---@param direction "older"|"newer"
---@param cycle CycleState
---@param opts { workspace: string, current: string }
---@return { text: string?, state: CycleState }
function M.cycle(direction, cycle, opts)
	local entries = M.entries({ workspace = opts.workspace })
	if #entries == 0 then
		return { text = nil, state = cycle }
	end

	local index = cycle.index
	local draft = cycle.draft

	if direction == "older" then
		if index == nil then
			-- Starting a walk: hold what the user had so it can be restored.
			draft = opts.current
			index = 1
		elseif index < #entries then
			index = index + 1
		else
			return { text = nil, state = cycle }
		end
		return { text = entries[index].text, state = { index = index, draft = draft } }
	end

	if index == nil then
		return { text = nil, state = cycle }
	end
	if index > 1 then
		index = index - 1
		return { text = entries[index].text, state = { index = index, draft = draft } }
	end

	-- Back past newest: restore the draft and leave the walk.
	return { text = draft or "", state = { index = nil, draft = nil } }
end

---Removes entries, optionally scoped to one workspace.
---
---Filters what is actually **on disk** rather than this session's ring. The ring
---is capped at `limit` and loaded once, so rewriting from it silently destroyed
---entries appended by other instances since load, plus entries for other
---workspaces that had fallen off this instance's cap -- a "clear this workspace"
---that deleted another project's history.
---@param opts { workspace?: string }?
---@return integer removed
---@return boolean ok false when the file could not be rewritten
function M.clear(opts)
	opts = opts or {}
	ensure_loaded()

	local pok, on_disk = pcall(current_store().load)
	if not pok then
		warn_once("clear", "could not read history file; nothing was cleared")
		return 0, false
	end

	local kept = {}
	local removed = 0
	for _, entry in ipairs(on_disk) do
		if opts.workspace and entry.workspaceRoot ~= opts.workspace then
			table.insert(kept, entry)
		else
			removed = removed + 1
		end
	end

	local ok = attempt_write("rewrite", function()
		return current_store().rewrite(kept)
	end)
	if not ok then
		return 0, false
	end

	-- Rebuild the ring from what survived so the session agrees with disk.
	ring = {}
	for _, entry in ipairs(kept) do
		insert_entry(entry)
	end
	return removed, true
end

---Drops all cached session state so the next use re-resolves `history.path` and
---re-reads the file. Called from `state.setup`, because the store adapter and
---the loaded ring otherwise latch for the process lifetime -- a second `setup()`
---with a different path kept writing to the old file, and suppressed warnings
---never cleared after the user fixed the state directory.
function M.reset()
	store = nil
	ring = {}
	loaded = false
	warned = {}
end

---Test seam: swap the storage adapter and reset cached session state.
---@param replacement HistoryStore|nil nil restores the file-backed store
function M._set_store(replacement)
	M.reset()
	store = replacement
end

return M
