-- The SEARCH/REPLACE match ladder: resolving hunks to buffer ranges.
--
-- Pure by construction -- text in, resolved ranges out -- so every level of the
-- ladder and every failure mode is testable without a buffer. The applying half
-- lives in buffer_edit.apply_hunks and is tested in edit_spec.
--
-- The ladder is deliberately flexible about whitespace and strict about
-- content: aider measured a 9x increase in errors with flexible matching
-- disabled, but a matcher that guesses at *content* can silently mangle code
-- the user never reviewed.
--
-- Registers into the shared harness; run via nvim/tests/vantage_spec.lua.
local test = require("support.harness").test
local helpers = require("support.helpers")

local eq = helpers.eq

local search_replace = require("vantage.search_replace")

local function hunk(search, replace)
	return { search = search, replace = replace }
end

local function lines(...)
	return table.concat({ ... }, "\n")
end

test("resolves an exact match to its buffer range", function()
	local text = lines("local a = 1", "local b = 2", "local c = 3")

	local resolved, failures = search_replace.resolve(text, { hunk("local b = 2", "local b = 22") })

	eq(#failures, 0)
	eq(#resolved, 1)
	eq(resolved[1].start_line, 2)
	eq(resolved[1].end_line, 2)
	eq(resolved[1].lines, { "local b = 22" })
end)

test("resolves a multi-line search block", function()
	local text = lines("one", "two", "three", "four")

	local resolved = search_replace.resolve(text, { hunk(lines("two", "three"), "TWO") })

	eq(resolved[1].start_line, 2)
	eq(resolved[1].end_line, 3)
	eq(resolved[1].lines, { "TWO" })
end)

test("resolves a replacement with more lines than the search", function()
	local text = lines("one", "two", "three")

	local resolved = search_replace.resolve(text, { hunk("two", lines("two-a", "two-b")) })

	eq(resolved[1].start_line, 2)
	eq(resolved[1].end_line, 2)
	eq(resolved[1].lines, { "two-a", "two-b" })
end)

test("resolves an empty replacement as a deletion", function()
	local text = lines("one", "two", "three")

	local resolved = search_replace.resolve(text, { hunk("two", "") })

	eq(resolved[1].lines, {})
end)

test("level 1 tolerates a trailing-whitespace difference", function()
	-- Models routinely normalize line ends; the buffer here has trailing space.
	local text = lines("local a = 1   ", "local b = 2")

	local resolved, failures = search_replace.resolve(text, { hunk("local a = 1", "local a = 9") })

	eq(#failures, 0)
	eq(resolved[1].start_line, 1)
	eq(resolved[1].level, 1)
end)

test("level 2 tolerates a dedented search block", function()
	-- The model re-emitted the block flush left; the buffer has it nested.
	local text = lines("function M.f()", "\tlocal a = 1", "\treturn a", "end")
	local search = lines("local a = 1", "return a")

	local resolved, failures = search_replace.resolve(text, { hunk(search, lines("local a = 2", "return a")) })

	eq(#failures, 0)
	eq(resolved[1].start_line, 2)
	eq(resolved[1].end_line, 3)
	eq(resolved[1].level, 2)
end)

test("level 2 re-indents the replacement to match the buffer", function()
	local text = lines("function M.f()", "\t\tlocal a = 1", "end")

	local resolved = search_replace.resolve(text, { hunk("local a = 1", "local a = 2") })

	-- Pasting the dedented replacement verbatim would flatten the scope.
	eq(resolved[1].lines, { "\t\tlocal a = 2" })
end)

test("level 2 preserves relative indentation inside the replacement", function()
	local text = lines("function M.f()", "\tlocal a = 1", "end")
	local replace = lines("if x then", "\tlocal a = 2", "end")

	local resolved = search_replace.resolve(text, { hunk("local a = 1", replace) })

	eq(resolved[1].lines, { "\tif x then", "\t\tlocal a = 2", "\tend" })
end)

test("level 2 does not indent blank lines in the replacement", function()
	local text = lines("function M.f()", "\tlocal a = 1", "end")
	local replace = lines("local a = 2", "", "local b = 3")

	local resolved = search_replace.resolve(text, { hunk("local a = 1", replace) })

	eq(resolved[1].lines, { "\tlocal a = 2", "", "\tlocal b = 3" })
end)

test("reports a hunk that matches nothing", function()
	local text = lines("local a = 1")

	local resolved, failures = search_replace.resolve(text, { hunk("local zzz = 9", "x") })

	eq(#resolved, 0)
	eq(#failures, 1)
	eq(failures[1].reason, "no_match")
	-- The first search line is what lets the user see what drifted.
	eq(failures[1].search_line, "local zzz = 9")
end)

test("reports an ambiguous hunk rather than taking the first match", function()
	local text = lines("x = 1", "y = 2", "x = 1")

	local resolved, failures = search_replace.resolve(text, { hunk("x = 1", "x = 9") })

	-- Silently picking an occurrence is how the wrong function gets edited.
	eq(#resolved, 0)
	eq(#failures, 1)
	eq(failures[1].reason, "ambiguous")
end)

test("reports an empty search block", function()
	-- The parser rejects these too; this is defense in depth, since an empty
	-- search would otherwise match at every position.
	local resolved, failures = search_replace.resolve("local a = 1", { hunk("", "x") })

	eq(#resolved, 0)
	eq(failures[1].reason, "empty_search")
end)

test("resolves several hunks in one pass", function()
	local text = lines("one", "two", "three", "four")

	local resolved, failures = search_replace.resolve(text, {
		hunk("one", "ONE"),
		hunk("four", "FOUR"),
	})

	eq(#failures, 0)
	eq(#resolved, 2)
	eq(resolved[1].start_line, 1)
	eq(resolved[2].start_line, 4)
end)

test("resolves every hunk against the original text", function()
	-- A replacement that changes the line count must not shift the range
	-- resolved for a later hunk: applying is what handles that, by going
	-- bottom-up.
	local text = lines("one", "two", "three", "four")

	local resolved = search_replace.resolve(text, {
		hunk("one", lines("one-a", "one-b", "one-c")),
		hunk("four", "FOUR"),
	})

	eq(resolved[2].start_line, 4)
	eq(resolved[2].end_line, 4)
end)

test("reports a hunk overlapping an already-resolved one", function()
	local text = lines("one", "two", "three")

	local resolved, failures = search_replace.resolve(text, {
		hunk(lines("one", "two"), "X"),
		hunk(lines("two", "three"), "Y"),
	})

	eq(#resolved, 1)
	eq(#failures, 1)
	eq(failures[1].reason, "overlap")
end)

test("keeps good hunks when another fails", function()
	local text = lines("one", "two")

	local resolved, failures = search_replace.resolve(text, {
		hunk("one", "ONE"),
		hunk("nope", "X"),
	})

	-- Partial application: without an agent loop there is no retry, so refusing
	-- the whole edit over one drifted anchor wastes the call.
	eq(#resolved, 1)
	eq(#failures, 1)
end)

test("does not match content that only shares its first and last line", function()
	-- Aider's "assume the middle drifted" strategy is deliberately absent: with
	-- direct-apply and undo as the only safety net, guessing at content can
	-- silently mangle code the user never reviewed.
	local text = lines("begin", "REAL BODY", "end")
	local search = lines("begin", "DIFFERENT BODY", "end")

	local resolved, failures = search_replace.resolve(text, { hunk(search, "x") })

	eq(#resolved, 0)
	eq(failures[1].reason, "no_match")
end)

test("resolve with no hunks is empty rather than an error", function()
	local resolved, failures = search_replace.resolve("local a = 1", {})

	eq(#resolved, 0)
	eq(#failures, 0)
end)

test("level 2 re-indents from the whole window when the first matched line is blank", function()
	-- Regression: the site indent used to come from buffer_lines[start_line]
	-- alone, and common_indent skips blank lines -- so a match whose first line
	-- is blank flush-lefted real code into an indentation-sensitive file.
	local text = lines("if x then", "", "\ta()", "\tb()", "end")

	local resolved, failures = search_replace.resolve(text, { hunk(lines("", "a()", "b()"), lines("", "c()", "d()")) })

	eq(#failures, 0)
	eq(resolved[1].level, 2)
	eq(resolved[1].lines, { "", "\tc()", "\td()" })
end)

test("level 2 still re-indents from a non-blank first matched line", function()
	local text = lines("if x then", "\ta()", "\tb()", "end")

	local resolved = search_replace.resolve(text, { hunk(lines("a()", "b()"), lines("c()", "d()")) })

	eq(resolved[1].lines, { "\tc()", "\td()" })
end)

test("an ambiguous hunk is reported without climbing the rest of the ladder", function()
	-- The levels are strictly nested, so >1 match at a strict level guarantees
	-- >1 at every looser one; climbing could only cost extra scans.
	local text = lines("\tx = 1", "y = 2", "  x = 1")

	local resolved, failures = search_replace.resolve(text, { hunk("x = 1", "x = 9") })

	eq(#resolved, 0)
	eq(failures[1].reason, "ambiguous")
end)
