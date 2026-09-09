-- Shared keybinding-hint rendering for Vantage's floating windows. Builds
-- the "label <key>" footer text used consistently across the prompt buffer,
-- the output popup, and the session output float, gated by ui.keybind_hints.
local state = require("vantage.state")

local M = {}

local function enabled()
	local ui = state.config.ui or {}
	if ui.keybind_hints == nil then
		return true
	end
	return ui.keybind_hints == true
end

---Builds footer text from an ordered list of hint segments.
---Each segment is either:
---  - a checkbox: { label = string, key = string?, checked = boolean }
---  - a plain action: { label = string, key = string }
---Checkbox segments always render (with the key suffixed only when hints are
---enabled); plain action segments render only when hints are enabled, since
---their label alone conveys no state worth showing.
---@param segments table[]
---@return string|nil footer text, or nil if there is nothing to show
function M.footer(segments)
	local hints_enabled = enabled()
	local parts = {}
	for _, segment in ipairs(segments or {}) do
		if segment.checked ~= nil then
			local box = segment.checked and "[x]" or "[ ]"
			if hints_enabled and segment.key then
				table.insert(parts, box .. " " .. segment.label .. " " .. segment.key)
			else
				table.insert(parts, box .. " " .. segment.label)
			end
		elseif hints_enabled and segment.key then
			table.insert(parts, segment.label .. " " .. segment.key)
		end
	end
	if #parts == 0 then
		return nil
	end
	return " " .. table.concat(parts, "  ") .. " "
end

return M
