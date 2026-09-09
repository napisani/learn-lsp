-- Buffer-side half of prompt history: binds the cycle keys and owns the
-- draft-capture mechanics.
--
-- Split from `history.lua` so the ring and its cursor arithmetic stay pure and
-- testable without a buffer. This module knows about buffers and keymaps; it
-- knows nothing about storage, dedup, or the cap.
--
-- Note the cycle keys default to <Up>/<Down> and are bound on *every* line, not
-- only the first and last. That is a deliberate trade: it means these two
-- buffers lose arrow-key cursor movement (use j/k) in exchange for cycling
-- behaving identically everywhere in the buffer. blink.cmp's own <Up>/<Down>
-- mappings include `fallback`, so its completion menu still wins while open.
local history = require("vantage.history")
local win_util = require("vantage.ui.window")

local M = {}

---Description prefix on every keymap this module binds, so a surface rebinding
---its keys can find and delete the previous set.
M.DESC_PREFIX = "Vantage history: "

---Removes cycle keymaps previously bound on `buf`, making `attach` idempotent.
---@param buf integer
function M.detach(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	for _, mode in ipairs({ "n", "i" }) do
		for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
			if (map.desc or ""):sub(1, #M.DESC_PREFIX) == M.DESC_PREFIX then
				pcall(vim.keymap.del, mode, map.lhs, { buffer = buf })
			end
		end
	end
end

---Binds the cycle keys on `buf` and returns a function that returns the walk to
---"newest". The returned function is always callable -- returning nil when no
---keys were bound only pushed a guard onto every call site.
---
---`workspace` is a function, not a value: the composition buffer outlives any
---single workspace, and resolving it at attach time froze it to whatever was
---current when the buffer was created.
---@param buf integer
---@param opts { keymaps: table, workspace: fun(): string }
---@return fun() reset
function M.attach(buf, opts)
	M.detach(buf)

	local function noop() end

	-- The documented kill switch: with history off, the keys must not be bound
	-- at all, so <Up>/<Down> keep moving the cursor.
	if not history.enabled() then
		return noop
	end

	local prev = win_util.as_list(opts.keymaps.history_prev)
	local next_ = win_util.as_list(opts.keymaps.history_next)
	if #prev == 0 and #next_ == 0 then
		return noop
	end

	---@type CycleState
	local cycle = {}

	local function step(direction)
		local result = history.cycle(direction, cycle, {
			workspace = opts.workspace(),
			current = win_util.buffer_text(buf),
		})
		cycle = result.state
		if result.text == nil then
			return
		end
		win_util.replace_buffer(buf, result.text)
	end

	for _, lhs in ipairs(prev) do
		vim.keymap.set({ "n", "i" }, lhs, function()
			step("older")
		end, { buffer = buf, silent = true, desc = M.DESC_PREFIX .. "older prompt" })
	end
	for _, lhs in ipairs(next_) do
		vim.keymap.set({ "n", "i" }, lhs, function()
			step("newer")
		end, { buffer = buf, silent = true, desc = M.DESC_PREFIX .. "newer prompt" })
	end

	return function()
		cycle = {}
	end
end

return M
