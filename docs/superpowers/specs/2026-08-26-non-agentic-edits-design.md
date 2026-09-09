# Non-Agentic Edits

Status: approved
Date: 2026-08-26

## Purpose

Let `:VantageEdit` run through the completion runtime -- a single model call
with no tools and no agent session -- and let a normal-mode edit reach anywhere
in the current file rather than only the cursor line.

Two scopes, two formats:

- **Visual selection** -> the model returns the complete replacement text for
  the selection, and Vantage splices it over the selected range.
- **Normal mode** -> the model returns SEARCH/REPLACE blocks, and Vantage
  matches and applies them anywhere in the current file.

## What already exists

Most of the visual path is built. `submit_edit` returns `replacementText`, and
`buffer_edit.apply(bufnr, range, text)` splices it over the range. Visual mode
already scopes to the live selection via `context.scoped` / `visual.live_range`.

The only thing stopping completion mode is one deliberate exclusion, at
`handlers.ts:20`:

> `editSelection` is deliberately excluded: its structured output (a
> tool-called `submit_edit` payload) has no completion-mode equivalent yet.

`annotateRange` already solves exactly this problem: its prompt says "if
`submit_annotations` is unavailable, return only JSON", and `completionResultFor`
runs the raw text back through the same validator the tool-call path uses. This
design copies that pattern. `buildEditPrompt` already carries the equivalent
sentence for `submit_edit`, so the visual path needs no prompt change at all.

## Format decision

### Why SEARCH/REPLACE rather than a patch

A real unified diff (`@@ -2,4 +3,5 @@`, applied with `patch` / `git apply`) is
the worst available option. Aider states it plainly:

> "GPT is terrible at working with source code line numbers. This is a general
> observation about *any* use of line numbers in editing formats, backed up by
> many quantitative benchmark experiments."

Aider's own "unified diff" format **drops the line numbers entirely**, at which
point a diff hunk and a SEARCH/REPLACE block are the same operation -- find this
text, put that text there -- differing only in delimiter syntax.

Aider measured udiff at 61% versus SEARCH/REPLACE at 20% on a refactoring suite,
but that benchmark measured *laziness*: the `-`/`+` framing stopped GPT-4 Turbo
eliding bodies with `# ...original code here...`. That was a 2024-era GPT-4
Turbo pathology, not a property of diffs.

SEARCH/REPLACE is chosen because it is what the ecosystem standardized on
(aider's default, avante's classic mode), so current models have the most
training exposure to it; it has no numbers to get wrong; and it is simpler to
parse *and* to fuzzy-match, since old and new text arrive as two clean blocks
rather than interleaved `-`/`+` markers.

The parser sits behind a seam so a future switch to udiff framing -- the known
mitigation if a model turns out to elide code -- stays contained.

### Canonical format

Filename before the fence, git merge-conflict markers inside:

    lua/vantage/monitor.lua
    ```lua
    <<<<<<< SEARCH
    local interval = config().interval_ms or 1000
    =======
    local interval = config().interval_ms or 500
    >>>>>>> REPLACE
    ```

The filename line is kept because it is part of what models trained on, but
normal mode edits *the current buffer*: a block naming a different path is
rejected, not written. Vantage stays out of multi-file editing -- that is the
agent's job.

### Alternatives considered

**Whole-file rewrite.** Reuses `buffer_edit.apply` unchanged with the whole
buffer as the range, and can never fail to apply. Rejected because output tokens
scale with the file rather than the change: slow and expensive past a few
hundred lines, and truncation silently destroys the tail of the file.

**Tool-based iterative edits** (avante's `replace_in_file`). Disqualified by
construction: it requires an agent loop, and this feature is about the
non-agentic runtime. Worth noting that when avante switched to it, users pushed
back hard -- changes arrived "with no explanation and it is hard to do a proper
review" -- and the fix was `disabled_tools = { "replace_in_file" }`.

**Fast-apply model** (Morph, Cursor-style). A second specialized model merges a
loose edit snippet at 96-98% accuracy. Rejected: it needs another provider and
API key for a feature whose whole point is one cheap local call.

**Diff + accept/reject gate** (CodeCompanion's `gda`/`gdr`). Rejected for now.
Edits apply directly and Vim's undo is the safety net, which is what
`:VantageEdit` already does. Revisit if multi-hunk edits prove hard to review.

## Protocol

```ts
export const EditSelectionParamsSchema = BaseRequestParamsSchema.extend({
  range: RangeSchema,
  selectedText: z.string(),
  instruction: z.string().min(1),
  runtime: RuntimeSchema.optional(),                 // new
  scope: z.enum(['selection', 'file']).optional(),   // new, defaults to 'selection'
});

export const EditHunksResultSchema = z.object({
  kind: z.literal('edits'),
  hunks: z.array(z.object({ search: z.string(), replace: z.string() })),
  telemetry: AgentRuntimeTelemetrySchema.optional(),
});
```

`scope` selects the result kind, so there is never ambiguity about what came
back: `'selection'` yields the existing `{ kind: 'edit', replacementText }`,
`'file'` yields `{ kind: 'edits', hunks }`. Omitting `scope` means `'selection'`,
so existing callers are unaffected.

Under `scope: 'file'`, `range` is the whole buffer (line 1 to the last line) and
`selectedText` is the entire file's text. The model cannot author a SEARCH block
without seeing the text it must match, so the whole file is what it gets. The
fields keep their existing types; only their extent changes.

The "edit stays agent-only for now" comment at `params.ts:17` is deleted rather
than left contradicting the code.

## One format, both runtimes

The agent path gets a `submit_edits` tool whose parameter is **the
SEARCH/REPLACE text as a string**, not a pre-structured hunks array:

```ts
parameters: options.Type.Object({ blocks: options.Type.String() })
```

This mirrors `submit_edit`, which already passes `replacementText` as a plain
string. The payoff is one format and one parser regardless of runtime: the agent
and the completion call emit identical blocks, so the training-exposure argument
holds in agent mode too. Accepting JSON hunks from the agent and text from the
completion path would mean two formats, two parsers, and two sets of bugs.

`parseSearchReplaceBlocks(text) -> hunks` lives in `markdown-utils.ts` beside
`parseEditPayload` and `parseAnnotationPayload`.

## Handlers

Three edits, each following `annotateRange`:

```ts
COMPLETION_ELIGIBLE_METHODS = new Set([..., 'editSelection'])

completionPromptFor:  case 'editSelection' ->
  params.scope === 'file' ? buildFileEditPrompt(params) : buildEditPrompt(params)

completionResultFor:  case 'editSelection' ->
  params.scope === 'file'
    ? { kind: 'edits', hunks: parseSearchReplaceBlocks(text) }
    : { kind: 'edit', replacementText: parseEditPayload(text) }
```

`buildEditPrompt` is unchanged. New `buildFileEditPrompt` states the block
format, the "if `submit_edits` is unavailable, return only the blocks" fallback,
the rule that every block targets the current file, and the requirement that each
SEARCH block carry enough context to match exactly once.

**The file is presented without line-number prefixes.** `buildAnnotationPrompt`
numbers its lines (`12 | local x = 1`) because annotations anchor by line number.
Doing that here would be fatal: the model would copy the prefixes into its SEARCH
blocks, and nothing would ever match the real buffer. SEARCH/REPLACE anchors by
text, so the text must be verbatim.

## Matching

Matching happens in **Lua against the live buffer**, not in the backend. The
request is async and the buffer can change between send and arrival, so line
numbers resolved backend-side would be stale. The backend parses text into
hunks; Lua decides where they land.

Two modules, split along the same line as `history` (pure ring) versus
`history_keymap` (buffer-aware):

- **`lua/vantage/search_replace.lua`** -- new, pure. Takes the buffer's text and
  the hunks; returns resolved ranges, the indentation-adjusted replacement for
  each, and a list of failures. Touches no buffer API, so the whole ladder is
  unit-testable against plain strings.
- **`lua/vantage/buffer_edit.lua`** -- existing, gains `apply_hunks(bufnr,
  resolved)`. Owns the ordering, the `nvim_buf_set_lines` calls, and the
  `undojoin` that makes them one undo step. It already owns `apply` for the
  selection path, so both write paths stay in one place.

### The ladder

Each hunk's `search` is resolved against the buffer, stopping at the first level
that produces **exactly one** match:

| Level | Tolerates | Why |
|---|---|---|
| 0 -- exact | nothing | Fast path; most hunks land here |
| 1 -- trailing whitespace | dropped/added trailing spaces | Models routinely normalize line ends |
| 2 -- relative indentation | different absolute indent, same relative shape | Models re-emit blocks dedented to column 0 |

Level 2 re-indents the *replacement* by the delta it found, so a dedented block
does not flatten the scope it lands in.

Aider's "match first and last line, assume the middle drifted" strategy is
deliberately **not** implemented. With direct-apply and undo as the only safety
net, a fuzzy match that guesses at content can silently mangle unreviewed code.
The rule is flexible about whitespace, strict about content: every level still
requires the full text to match modulo formatting.

Aider measured a **9x increase in errors** with flexible matching disabled, so
levels 1 and 2 are not optional polish.

### Failure modes, all loud

- **No match** -> hunk skipped, reported with its first search line
- **Multiple matches** -> skipped as ambiguous, never "take the first"; silently
  picking an occurrence is how the wrong function gets edited
- **Empty `search`** -> rejected. Aider uses it to mean "create new file";
  Vantage does not create files
- **Overlapping resolved ranges** -> the later hunk is skipped and reported

### Applying

```
1. resolve EVERY hunk against the ORIGINAL buffer text -> ranges
2. reject overlaps
3. sort ranges bottom-up
4. apply each with nvim_buf_set_lines, undojoin between them
```

Resolving up front against the original matters: applying hunk 1 shifts the
lines under hunk 2, so interleaving match-and-apply would corrupt later matches.
Bottom-up application then keeps every unresolved index valid without
recomputation.

`undojoin` (pcall-guarded -- it errors when it follows an undo) makes the whole
edit **one undo step**, so `u` reverts every hunk together. Rewriting the entire
buffer in a single `set_lines` would also be atomic but would destroy extmarks,
folds, and marks in untouched regions.

**Partial application**: matched hunks apply, unmatched ones are reported, all
inside the single undo block. All-or-nothing is defensible but worse here --
without an agent loop there is no automatic retry, so refusing a whole edit over
one drifted anchor wastes the call. Failures surface as a notify with the count
plus detail in the output float via `ui.show_markdown`, matching every other
Vantage failure.

## Prompt-buffer runtime toggle

`:VantageEdit` must offer the same `[x] agent <C-r>` toggle in the prompt buffer
that `:VantageQuestion` does, so the runtime is switchable per invocation rather
than only via `runtime=` or config.

No new machinery is needed. `prompt_authoring.resolve` and
`ui/prompt_buffer.open` already take `runtime` and `show_runtime_toggle`
generically, `prompt_buffer` already renders the checkbox segment and binds
`toggle_runtime` (default `<C-r>`), and `state.command_runtime(name)` already
resolves any command by name. `model_command.edit` is simply missing the three
lines `model_command.question` has:

```lua
function M.edit(opts)
  local bufnr = vim.api.nvim_get_current_buf()
  local params = scoped_context(opts)
  local default_runtime = opts.runtime or state.command_runtime("edit")   -- new

  prompt_authoring.resolve({
    kind = "edit",
    params = params,
    command_opts = opts,
    runtime = default_runtime,          -- new
    show_runtime_toggle = true,         -- new
    on_submit = function(instruction, runtime)
      params.runtime = runtime or default_runtime   -- new
      request_edit(bufnr, params, instruction)
    end,
  })
end
```

The toggle chosen in the prompt buffer wins over `commands.edit.runtime`, which
in turn wins over the `"agent"` default -- the same precedence question already
has.

## Lua wiring

- `reject_runtime_option` -> `with_runtime_option` for edit; delete the
  "VantageEdit does not support a runtime= option yet" error
- `state.default_config()` gains `commands.edit.runtime = "agent"`, matching
  explain/question
- `model_command.edit` sets `scope` from whether a range is present, and
  switches on the returned kind
- README Public API and Configuration Reference updated in the same change, per
  AGENTS.md

No new commands and no new keymaps. `:VantageEdit runtime=completion` starts
working, and the visual path becomes non-agentic with a config flag.

## Behavior change

Normal-mode `:VantageEdit` currently scopes to the cursor line. It becomes
whole-file. This is a deliberate change to a shipped command, not an addition:
"edit this one line" was never very useful, and the point of the feature is
letting the model designate edits anywhere in the file.

## Testing

**TypeScript.** `markdown-utils.test.ts` is new -- that file has no tests today,
and `parseSearchReplaceBlocks` is the highest-risk pure function in the change:

- canonical block with filename and fence; multiple blocks in one response
- **nested code fences inside the replace body** -- avante issue #832, the case
  a naive fence-splitter gets wrong
- prose around the blocks, since models editorialize
- unterminated block rejected, never silently truncated
- empty `search`, foreign filename, CRLF normalization

Extended: `handlers.test.ts` (completion eligibility; `scope` selects the result
kind; omitted `scope` still means `selection`), `prompts.test.ts`
(`buildFileEditPrompt` carries the format and the current-file rule),
`protocol.test.ts` (new fields parse; omitting them stays valid).

**Lua.** New `search_replace_spec.lua` for the ladder, pure and buffer-free:
exact, trailing-whitespace, dedented-with-reindent, no-match, ambiguous,
overlap, and the bottom-up ordering guarantee. Registered in `vantage_spec.lua`'s
`SPECS` per AGENTS.md.

Extended `edit_spec.lua` for behavior: visual still replaces exactly the
selection, normal-mode hunks land on the right lines, partial failure applies
what matched, `runtime=completion` no longer errors, and a multi-hunk edit is a
**single undo step** -- the test that matters most, since `u` is the entire
safety net.

Prompt-buffer toggle coverage mirrors the existing question tests: the edit
prompt buffer binds `toggle_runtime` and renders the `[x] agent` segment, and the
runtime chosen there reaches `params.runtime`. Per the headless-nvim caveat in
AGENTS.md these assert against `nvim_buf_get_keymap` rather than trying to
observe insert mode.

## References

- [Unified diffs make GPT-4 Turbo 3X less lazy](https://aider.chat/docs/unified-diffs.html)
- [Edit formats](https://aider.chat/docs/more/edit-formats.html) -- aider
- [Using the Inline Interaction](https://codecompanion.olimorris.dev/usage/inline) -- CodeCompanion
- [avante discussion #2029](https://github.com/yetone/avante.nvim/discussions/2029) -- SEARCH/REPLACE vs `replace_in_file`
- [avante issue #832](https://github.com/yetone/avante.nvim/issues/832) -- code blocks break block parsing
