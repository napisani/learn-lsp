# Prompt-building public API design

Date: 2026-08-25
Status: implemented (see Implementation amendments at the end)

## Problem

`pub/dotfiles-nix/mods/dotfiles/nvim` carries a body of AI-action logic —
`lua/user/snacks/ai_actions/common.lua`, `lua/user/snacks/ai_actions.lua`, and the
`<leader>a*` keymaps in `lua/user/plugins/ai/wiremux.lua` — that overlaps what
vantage already does, and duplicates logic vantage arguably should own.

Two specific behaviors motivated this work:

- `<leader>am` (and its siblings `<leader>ae`, `<leader>a?`) capture the current
  file/selection, collect a line of user input via `Snacks.input`, and append the
  assembled entry to a staging buffer. The single-line `Snacks.input` is a worse
  input surface than vantage's own multi-line prompt buffer, which already does
  reference expansion and runtime toggling.
- `common.capture_context` contains carefully-derived visual-selection logic that
  vantage cannot currently express at all (see "Visual-selection fidelity" below).

The goal is **not** to relocate the dotfiles pipeline into vantage. Those keymaps
terminate in `user.prompt_builder`, a persistent staging buffer whose contents are
later shipped to an *external agent pane* (a terminal running another agent, routed
by wiremux). Vantage sends requests to its own Node/Pi backend and consumes
structured results in-editor. Those are different systems.

The goal is to identify which *capabilities* in that dotfiles code are genuinely
vantage's, expose them as public API in vantage's own conventions, and let the
config become a thin consumer.

## Non-goals

These are deliberate boundaries, not deferred work:

- ~~**Vantage does not own the composition/staging concept.**~~ **Superseded on
  2026-08-25** by `2026-08-25-composition-buffer-design.md`. At the time of this
  spec, accumulating entries into a buffer was to stay in the user's Neovim
  config, with Vantage exposing only the primitives used to build each entry.
  That boundary was later reversed: composition is now a first-class Vantage
  subsystem (`lua/vantage/composition.lua`, `:VantageCompose*`), so every
  consumer of the plugin gets it rather than only configs that hand-rolled one.
  The rest of this document's non-goals still stand.
- **Vantage does not own the picker flow.** No picker dependency, and no picker
  provider abstraction. Vantage stays on `vim.ui.input` / its `ui2` provider and
  the one existing `vim.ui.select`.
- **Vantage does not own git plumbing.** Ref sources like git tracked / changed /
  branch-diff / conflicts remain config-side. Vantage never shells out to git to
  build a file list.
- **No backend or protocol changes.** This is Lua-only. Composed context reaches
  the model through the existing request fields, via the config passing text into
  existing public functions (e.g. `vantage.question({ args = composed })`).
- **Wiremux route management, Vocal, and the memo register utilities do not move.**
  `<leader>ao`/`aq`/`aw`/`av`/`ai` and `append_context_to_register` /
  `paste_context_register` / `clear_context_register` are unrelated to vantage.

## Scope

In scope: `<leader>am`, `<leader>ae`, `<leader>a?`.

Deferred to a later phase: `<leader>af*` (file/git reference pickers) and
`<leader>as` / `<leader>ap` (skill and canned-prompt pickers, which are largely
deduplication against vantage's existing `listSkills` and prompt authoring).

## Piece 1 — Visual-selection fidelity

This is a genuine vantage bug fix that happens to also be the enabler for the
refactor.

### The gap

`model_command.scoped_context(opts)` derives its range solely from
`opts.range`/`opts.line1`/`opts.line2`. That is correct for `:'<,'>VantageExplain`,
because Vim commits the `'<` / `'>` marks for a `:`-range command before the
callback runs. It has **no answer for a plain Lua-function keymap bound in visual
mode** — `opts.range` is absent, so the command silently degrades to the cursor
line while the user believes their selection was sent.

`common.capture_context` in the dotfiles config documents exactly why reading
`'<` / `'>` from such a keymap is wrong: those marks are only committed when
Visual mode is formally exited (Esc, an operator, or a `:`-range command). A
Lua callback goes through none of those, so at call time the marks still hold the
*previous* properly-closed selection. The live anchor (`v`) and cursor (`.`)
positions track the active selection instead.

### Design

New internal module `lua/vantage/visual.lua`:

- `M.live_range()` → `start_line, end_line`, or `nil` when not in visual mode.

It ports two things from `capture_context`:

1. Prefer live `v` / `.` while still in visual mode (`v`, `V`, or `<C-v>`), falling
   back to `'<` / `'>` once visual mode has actually been left.
2. Normalize reversed selections (anchor after cursor) by swapping.

The linewise-`V` column correction in `capture_context` exists because `v` / `.`
report raw cursor columns rather than full-line bounds. Vantage's `context.lua`
works in whole lines (`line_range` derives columns itself from the fetched lines),
so `live_range` returns lines only and the column correction is not needed. This
is a deliberate simplification, not an omission.

`scoped_context(opts)` then resolves in this precedence:

| # | Condition | Source | Status |
|---|---|---|---|
| 1 | `opts.range > 0` | `context.line_range(opts.line1, opts.line2)` | unchanged (`:'<,'>` path) |
| 2 | `visual.live_range()` non-nil | `context.line_range(start, end)` | **new** (Lua visual keymap path) |
| 3 | otherwise | `context.current_line()` | unchanged |

Detection is **automatic** — no `opts.visual` flag. Every existing vantage command
(`explain`, `question`, `edit`, `annotate`, `search`, `generate_walkthrough`) gains
correct visual-keymap behavior with no caller change.

Accepted risk: a caller invoking e.g. `vantage.explain({})` from a visual-mode
keymap today gets the cursor line and would now get the selection. That is the
behavior being fixed, and explicit `opts.range` still wins, so the `:'<,'>` path
is unaffected.

## Piece 2 — Public prompt-buffer API

Expose the existing `ui/prompt_buffer.open` as public API.

```lua
vantage.prompt({
  kind = "memo",                  -- buffer-var tag; filetype stays markdown
  params = ctx,                   -- context params, used for @ref / /skill resolution
  runtime = "agent",              -- optional, seeds the runtime checkbox
  show_runtime_toggle = false,    -- optional
  on_submit = function(text, runtime) ... end,
})
```

Returns `buf, win`. Callers inherit everything the prompt buffer already does:
multi-line markdown input, `<CR>` submit in insert or normal mode, `<Esc>` →
normal → `<Esc>`/`q` abort, and `@path` / `/skill` reference expansion applied to
the submitted text.

`prompt_authoring.resolve` stays internal — it is the "use inline command args if
present, else open the buffer" wrapper, which a config-side keymap does not need.

`AGENTS.md`'s rule is command → function (every user command needs a public Lua
function), so a function-only addition needs no `:Vantage*` command. The README
Public API section must still gain a row for it.

## Piece 3 — Reference formatting helper

```lua
vantage.format_reference({ path = "lua/x.lua", start_line = 12, end_line = 40 })
--> "@lua/x.lua lines 12-40"

vantage.format_reference({ path = "lua/x.lua" })
--> "@lua/x.lua"
```

Rationale: `@path` is vantage's own contract — `ui/prompt_buffer.lua`'s
`references_section` is what parses it — so vantage should own emitting it rather
than letting consumers hand-roll a format that can drift from the parser.

Deliberately **not** exposed: selection code-fencing and entry labels
(`Instruction:`, `---` separators). Those are generic markdown and presentation
choices belonging to the consumer, so they stay in the config. Keeping them out
prevents vantage's public surface from accreting formatting opinions it has no
contract for.

Known limitation, accepted for now: `references_section` matches
`@([%w%._%-%/%\\]+)`, which stops at `:` and captures no line numbers. Line ranges
emitted by `format_reference` are therefore **decorative** — human- and
model-readable, but resolved as file-level references. Teaching the parser to
capture line ranges is deferred; it would change existing reference-resolution
behavior and its tests for no present need.

## Piece 4 — Rewire the config

`ai_actions.append_snack_context_to_prompt_builder` is rewritten to drop
`common.capture_context` and `Snacks.input`, and instead:

1. call `vantage.prompt({ ... })`
2. in `on_submit`, assemble the entry from `vantage.format_reference` plus its own
   labels and selection fence
3. `pb.append_text(...)` as today

The `<leader>am` / `<leader>ae` / `<leader>a?` bindings do not change — only their
implementation.

Left in place for this phase: `common.lua` (its `format_reference_payload` and
`build_context_message` are still used by the deferred `af*` path,
`prompt_builder.append_references`, and `ai_actions/wiremux.lua`), plus
`stage_context` and the register-memo utilities.

Incidental cleanup available at any time: `common.format_file_ref` and
`common.format_selection` have no callers outside `common.lua` itself — only
`build_context_message` uses them.

## Testing

Vantage (`nvim/tests/vantage_spec.lua`, currently 99 tests, all must stay green):

- `visual.live_range()`: charwise `v`, linewise `V`, blockwise `<C-v>`, reversed
  selection, and not-in-visual-mode returning `nil`.
- `scoped_context` precedence: explicit `opts.range` beats live visual, which beats
  current line.
- `vantage.prompt`: `on_submit` receives expanded text and the runtime value;
  cancelling never invokes `on_submit`.
- `vantage.format_reference`: with and without a line range.

**Known testing risk.** Driving real modes in headless Neovim is unreliable. An
earlier fix in this codebase hit this: the prompt buffer's `startinsert` runs
inside `vim.schedule()` and only takes effect once Neovim next reads input, so a
synchronous test can never observe insert mode — `vim.wait` does not help, and the
test had to assert the buffer's keymap table instead of driving the transition.
Visual mode may need the same treatment. Preferred order of attack:

1. `vim.cmd("normal! vjj")` to establish a real selection synchronously, then call
   the function directly.
2. Failing that, give `live_range` a seam that accepts the anchor/cursor positions
   so the range math is unit-testable without a real mode.

The dotfiles config has no test infrastructure, so Piece 4 is verified manually.

## Sequencing

1. **Piece 1** — `visual.lua` + `scoped_context`. Independent and valuable on its
   own (fixes visual-keymap capture for every existing command); ship first.
2. **Piece 2 + 3** — `vantage.prompt`, `vantage.format_reference`, README Public
   API rows.
3. **Piece 4** — rewire the dotfiles `am`/`ae`/`a?` keymaps.
4. **Later** — `af*` and `as`/`ap`, under the non-goals above: pickers and git
   logic stay config-side, so vantage's part is limited to an API for inserting
   refs into an open prompt buffer.

## Implementation amendments

All three in-scope pieces shipped. Five things ended up differing from the design
above; recorded here because each was a deliberate correction rather than drift.

### 1. No `'< / '>` fallback in `live_range` (corrects the Piece 1 design)

The design said `live_range` should fall back to the `'<` / `'>` marks "once
Visual mode has actually been left". That is wrong for **automatic** detection.
Outside visual mode those marks are indistinguishable from a stale leftover, so
falling back to them would make every ordinary normal-mode invocation silently
reuse the last selection instead of the cursor line — a worse bug than the one
being fixed.

`live_range` therefore returns `nil` unless a selection is live right now. The
fallback the original `capture_context` needed only existed because its caller
passed the mode in explicitly; automatic detection cannot rely on that.
`nvim/tests/context_spec.lua` pins the property directly: make a selection, close
it properly so the marks *are* committed, and assert `live_range()` is still nil.

### 2. Two duplicate helpers collapsed, not one modified

`model_command.lua` and `annotation_command.lua` each carried a byte-identical
private `range_context`. Rather than add the visual branch twice, the resolution
moved into `context.selected_range` / `context.scoped` and both call sites now
delegate. Precedence lives in exactly one place.

### 3. `vantage.context(opts)` added — three public functions, not two

Piece 4 needs the same context vantage's own commands capture. Without exposing
it, the config would have had to reimplement the visual-selection logic that
Piece 1 had just centralized, which defeats the point. Added alongside `prompt`
and `format_reference`.

### 4. `opts.title` added to the prompt buffer

The `Snacks.input` being replaced rendered a title ("Instruction", "Question"),
and the prompt float had no equivalent — a caller routing several distinct flows
through one surface would give the user no indication of which they invoked.
`opts.title` renders a centered border caption.

Implementation note worth keeping: title and footer must be applied in a **single**
`nvim_win_set_config` call. Setting one alone clears the other on a float, so
`refresh_footer` builds one combined config table. There is a test asserting the
footer survives setting a title.

### 5. `format_reference` collapses equal bounds

The design specified `@path` / `@path lines N-M`. A single-line scope — every
normal-mode invocation — would render `@path lines 42-42`. Equal bounds now
collapse to `@path line 42`, so a normal-mode reference keeps its line number
instead of either degrading to a bare `@path` or reading awkwardly.

### Testing outcome

The flagged headless-mode risk did not materialize: `vim.cmd("normal! vjj")`
establishes a real selection synchronously and stays in visual mode, so option 1
from the testing section worked and the anchor-injection seam was not needed.

Suite went from 99 to 113 tests. The end-to-end fix was verified by reverting the
new branch and confirming the visual-keymap test failed with
`expected "local b = 2\nlocal c = 3" but got "local c = 3"` — the exact
degradation being fixed.

Piece 4 was verified manually against the real plugin, per plan: visual mode
produces `@mod.lua lines 1-2` plus a fenced selection, normal mode produces
`@mod.lua line 2` with no fence, and `@`-references in the typed body expand.
