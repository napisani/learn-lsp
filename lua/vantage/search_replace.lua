-- Resolving SEARCH/REPLACE hunks to buffer ranges.
--
-- Pure on purpose: text and hunks in, ranges out. The buffer half lives in
-- `buffer_edit.apply_hunks`, so the whole ladder below is testable against
-- plain strings -- the same split as `history` (pure ring) versus
-- `history_keymap` (buffer-aware).
--
-- The ladder is flexible about whitespace and strict about content. Aider
-- measured a 9x increase in errors with flexible matching disabled, so levels 1
-- and 2 are not optional polish. But their "match the first and last line and
-- assume the middle drifted" strategy is deliberately absent: edits apply
-- straight to the buffer with undo as the only safety net, and a matcher that
-- guesses at content can silently mangle code nobody reviewed.
local M = {}

---@class EditHunk
---@field search string
---@field replace string

---@class ResolvedHunk
---@field start_line integer 1-based, inclusive
---@field end_line integer 1-based, inclusive
---@field lines string[] replacement lines, re-indented to the match site
---@field level integer which ladder level matched, for tests and diagnostics

---@class HunkFailure
---@field reason "empty_search"|"no_match"|"ambiguous"|"overlap"
---@field search_line string first line of the hunk's search block

---Normalizes line endings and splits. Shared with `buffer_edit`, so the two
---apply paths cannot drift on newline handling.
---@param text string?
---@return string[]
function M.split_lines(text)
	local normalized = (text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
	return vim.split(normalized, "\n", { plain = true })
end

local split_lines = M.split_lines

---Replacement text as lines. A blank replacement is a deletion, not a blank
---line: `vim.split("", "\n")` yields one empty string, which would leave an
---stray line behind.
function M.replacement_lines(text)
	if text == nil or text == "" then
		return {}
	end
	return split_lines(text)
end

local replacement_lines = M.replacement_lines

---Like `replacement_lines`, but drops one trailing empty line.
---
---Named for its rule rather than sharing `replacement_lines`' name: the
---selection-scope apply path wants a trailing newline in the model's text to
---mean "end of the last line", not "add a blank line".
---@param text string?
---@return string[]
function M.replacement_lines_trimmed(text)
	local lines = split_lines(text)
	if #lines > 1 and lines[#lines] == "" then
		table.remove(lines, #lines)
	end
	return lines
end

local function strip_trailing(line)
	return (line:gsub("%s+$", ""))
end

local function leading_whitespace(line)
	return line:match("^[ \t]*") or ""
end

local function is_blank(line)
	return line:match("^%s*$") ~= nil
end

---The longest leading-whitespace prefix shared by every non-blank line.
---
---Blank lines are excluded because they carry no indentation to agree with, and
---counting them would collapse the common prefix to "" for any block with an
---interior blank line.
---@param lines string[]
---@return string
local function common_indent(lines)
	local prefix = nil
	for _, line in ipairs(lines) do
		if not is_blank(line) then
			local indent = leading_whitespace(line)
			if prefix == nil then
				prefix = indent
			else
				local limit = math.min(#prefix, #indent)
				local shared = 0
				while shared < limit and prefix:sub(shared + 1, shared + 1) == indent:sub(shared + 1, shared + 1) do
					shared = shared + 1
				end
				prefix = prefix:sub(1, shared)
			end
			if prefix == "" then
				return ""
			end
		end
	end
	return prefix or ""
end

---Removes `indent` from the front of every line that has it.
local function dedent(lines, indent)
	if indent == "" then
		return lines
	end
	local out = {}
	for _, line in ipairs(lines) do
		out[#out + 1] = line:sub(1, #indent) == indent and line:sub(#indent + 1) or line
	end
	return out
end

---Prefixes every non-blank line with `indent`. Blank lines are left alone so a
---re-indented replacement does not introduce trailing whitespace.
local function indent_lines(lines, indent)
	if indent == "" then
		return lines
	end
	local out = {}
	for _, line in ipairs(lines) do
		out[#out + 1] = is_blank(line) and line or (indent .. line)
	end
	return out
end

---@param a string[]
---@param b string[]
---@param transform fun(line: string): string
local function sequences_equal(a, b, transform)
	if #a ~= #b then
		return false
	end
	for index = 1, #a do
		if transform(a[index]) ~= transform(b[index]) then
			return false
		end
	end
	return true
end

local function identity(line)
	return line
end

---Removes each block's *own* common indentation, so a block the model emitted
---flush-left still matches a nested one -- provided the relative shape agrees.
local function dedent_own(lines)
	return dedent(lines, common_indent(lines))
end

---Every start line where `search_lines` matches.
---
---`prepare` optionally rewrites both the search block and each candidate window
---before comparison; that single hook is what distinguishes the ladder's levels,
---so the off-by-one window bound exists once rather than once per level.
---@param buffer_lines string[]
---@param search_lines string[]
---@param transform fun(line: string): string per-line comparison normalizer
---@param prepare (fun(lines: string[]): string[])?
---@return integer[]
local function find_matches(buffer_lines, search_lines, transform, prepare)
	local target = prepare and prepare(search_lines) or search_lines
	local matches = {}
	local span = #search_lines

	for start = 1, #buffer_lines - span + 1 do
		local window = {}
		for offset = 0, span - 1 do
			window[offset + 1] = buffer_lines[start + offset]
		end
		if prepare then
			window = prepare(window)
		end
		if sequences_equal(window, target, transform) then
			matches[#matches + 1] = start
		end
	end
	return matches
end

---Locates one hunk.
---
---Stops at the first level producing exactly one match. It also stops at the
---first level producing *several*: the levels are strictly nested -- level-1
---equality forces identical leading whitespace, hence identical `common_indent`,
---hence identical dedent behavior -- so a level that matches twice guarantees
---every looser level matches at least twice. Climbing past ambiguity could never
---disambiguate, it could only cost two more full scans.
---@param buffer_lines string[]
---@param search_lines string[]
---@return integer? start_line
---@return integer? level
---@return string? failure_reason
local function locate(buffer_lines, search_lines)
	local ladder = {
		function()
			return find_matches(buffer_lines, search_lines, identity)
		end,
		function()
			return find_matches(buffer_lines, search_lines, strip_trailing)
		end,
		function()
			return find_matches(buffer_lines, search_lines, strip_trailing, dedent_own)
		end,
	}

	for level, attempt in ipairs(ladder) do
		local matches = attempt()
		if #matches == 1 then
			return matches[1], level - 1, nil
		end
		if #matches > 1 then
			return nil, nil, "ambiguous"
		end
	end

	return nil, nil, "no_match"
end

---Resolves `hunks` against `text`.
---
---Every hunk is resolved against the *original* text. Applying one hunk shifts
---the lines under the next, so interleaving match-and-apply would corrupt later
---matches; `buffer_edit.apply_hunks` handles that by going bottom-up.
---@param text string the buffer's current contents
---@param hunks EditHunk[]
---@return ResolvedHunk[] resolved
---@return HunkFailure[] failures
function M.resolve(text, hunks)
	local buffer_lines = split_lines(text)
	local resolved = {}
	local failures = {}

	local function fail(reason, search)
		failures[#failures + 1] = {
			reason = reason,
			search_line = split_lines(search or "")[1] or "",
		}
	end

	for _, hunk in ipairs(hunks or {}) do
		local search = hunk.search or ""
		if search:match("%S") == nil then
			-- An empty search matches at every position, so this can only ever
			-- splice text somewhere arbitrary.
			fail("empty_search", search)
		else
			local search_lines = split_lines(search)
			local start_line, level, reason = locate(buffer_lines, search_lines)

			if not start_line then
				fail(reason, search)
			else
				local end_line = start_line + #search_lines - 1
				local overlaps = false
				for _, existing in ipairs(resolved) do
					if start_line <= existing.end_line and end_line >= existing.start_line then
						overlaps = true
						break
					end
				end

				if overlaps then
					fail("overlap", search)
				else
					local lines = replacement_lines(hunk.replace)
					if level == 2 then
						-- Re-anchor at the matched window's own common indent --
						-- the same quantity level 2 dedented by. Reading only the
						-- first line flush-lefts the replacement whenever that
						-- line is blank, since common_indent skips blank lines.
						local window = {}
						for line = start_line, end_line do
							window[#window + 1] = buffer_lines[line]
						end
						local site_indent = common_indent(window)
						lines = indent_lines(dedent_own(lines), site_indent)
					end
					resolved[#resolved + 1] = {
						start_line = start_line,
						end_line = end_line,
						lines = lines,
						level = level,
					}
				end
			end
		end
	end

	return resolved, failures
end

return M
