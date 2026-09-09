# Composition buffer design

Date: 2026-08-25
Status: implemented (see Implementation amendments at the end)

Supersedes the "Vantage does not own the composition/staging concept" non-goal in
`2026-08-25-prompt-building-public-api-design.md`. That boundary was drawn when
composition was assumed to stay personal workflow glue; the decision now is that
it is a first-class Vantage capability every consumer of the plugin can use.

## Problem

`pub/dotfiles-nix/mods/dotfiles/nvim/lua/user/prompt_builder.lua` is a staging
buffer: you accumulate `@`-refs, selections, skill invocations, and freeform
instructions into it over time, then send the whole thing to an agent in one
shot. It works, but it is personal-config-shaped in ways that block reuse:

- **The destination is hardwired.** `_submit_and_wipe` calls
  `wiremux.send_text` directly, so the module is only usable by someone routing
  to wiremux.
- **It silently loses work.** The buffer is created with `bufhidden = "wipe"`,
  so closing the split destroys everything staged. Verified empirically: after
  `:close` the buffer handle is invalid, which also means
  `find_prompt_builder_buf()`'s recovery scan over `nvim_list_bufs()` can never
  find anything — it is dead code.
- **Entry separation leaked to callers.** `ai_actions.lua` hand-rolls
  `"---\n\n" .. entry` and its own `prompt_builder_buffer_nonempty` check,
  because the module offers no "append an entry" concept.
- **No inspection or reset.** No `content()`, `is_empty()`, or `clear()`, so
  consumers reimplement them and the only way to empty the buffer is to send it.
- **Keymap hardcoded.** `<C-g>` is baked in, unlike every other Vantage surface.
- **Vestigial `setup()`** creates an augroup and does nothing else.

## Naming

Vantage already has `ui/prompt_buffer.lua`: an *ephemeral float that collects one
prompt and submits it*. A persistent staging buffer named "prompt builder" would
sit two letters away from it in code, config, and docs — a permanent confusion
source.

This subsystem is therefore **composition**: `lua/vantage/composition.lua`,
`vantage.compose*` functions, `:VantageCompose*` commands. That vocabulary is
already what this conversation and the superseded non-goal used for the concept.

| Concept | Module | Lifetime | Purpose |
|---|---|---|---|
| Prompt buffer | `ui/prompt_buffer.lua` | ephemeral float | collect one prompt, hand it to a callback |
| Composition | `composition.lua` | persistent split | accumulate many entries, send once |

## Non-goals

- **Vantage does not own reference pickers or git plumbing.** Unchanged from the
  prior spec. Composition accepts text; deciding *which* files to reference stays
  config-side.
- **No sink registry.** One `on_send` callback, deliberately (see below).
- **No structured entry model.** The buffer's text is the source of truth, which
  is what makes it freely editable before sending. No entry list, no metadata.
- **No backend or protocol changes.** Lua only.

## Design

### The buffer

Single global buffer, recovered by scanning for its buffer variable if the
module-level handle is lost.

| Option | Value | Note |
|---|---|---|
| name | `VantageComposition` | |
| `filetype` | `markdown` | |
| `buftype` | `nofile` | |
| `buflisted` | `false` | |
| `bufhidden` | **`hide`** | the fix — staged work survives closing the window |
| `swapfile` | `false` | |
| `modifiable` | `true` | it is a workspace, not a viewer |

Buffer variable `b:vantage_composition = true` is a **documented public
contract**, because integrations legitimately need to detect it (see
"Detection", below).

### Window

A bottom split (`rightbelow split`), reusing the existing window when the buffer
is already visible. Height is `clamp(min_height, max_height, lines * height)`,
carrying over the existing 10/32/0.32 behavior as configurable defaults.

### Public API

Flat `compose_*` names, matching Vantage's existing flat-function convention.

| Function | Command | Purpose |
|---|---|---|
| `compose()` | `:VantageCompose` | open or focus the buffer |
| `compose_send()` | `:VantageComposeSend` | send staged text, then clear/close per config |
| `compose_clear()` | `:VantageComposeClear` | empty the buffer, keep it |
| `compose_append(text, opts?)` | — | append an entry |
| `compose_content()` | — | staged text, trimmed, or `""` |
| `compose_is_empty()` | — | boolean |
| `is_composition_buffer(bufnr?)` | — | predicate for integrations |

Per `AGENTS.md`, the three commands each get a `command_names.lua` entry, a
`commands.lua` wrapper, and an `init.lua` function. The rest are Lua-only.

### Append semantics

`compose_append(text, opts?)` owns separation, which callers previously did
themselves:

- nil/empty text is ignored
- into an empty buffer: becomes the content
- into a non-empty buffer: inserts the configured separator block, then the text
- `opts.separator = false`: blank-line separation only, no rule — for appending
  reference payloads, matching the old `append_text` behavior
- appending shows the buffer, preserving the existing ergonomic

### Send semantics

1. Read the buffer, trim. Empty → warn, no-op, return false.
2. If `composition.on_send` is configured, call it with the text. A literal
   `false` return means failure; anything else (including `nil`) is success.
3. If it is not configured, route the text through Vantage's own `question`
   flow. This is the documented default so the feature is useful out of the box
   rather than inert until configured.
4. On success: clear if `clear_on_send`, close the window if `close_on_send`.

Failure must not clear — losing staged work because a send failed is the same
class of bug as `bufhidden = "wipe"`.

**Why a single callback rather than a named sink registry.** A registry would let
Vantage ship built-in destinations and let `:VantageComposeSend` take a name.
That was considered and rejected as speculative: one hook plus a documented
default covers "send via Vantage" and "send via anything else", and a registry
can be added later without breaking `on_send` if multi-destination need appears.

### Detection

The dotfiles config has blink.nvim completion sources that provide `@file` and
`/skill` completion *inside* the staging buffer, gated on its buffer variable —
four call sites across `blink.lua`, `completion/sources/prompt_files.lua`, and
`completion/sources/skills.lua`.

Vantage therefore exposes `is_composition_buffer(bufnr?)` as supported API, and
documents `b:vantage_composition`. Integrations use the predicate rather than
sniffing an implementation detail. No legacy `b:prompt_builder` variable is set —
consumers move to the predicate.

### Keymaps and hints

`ui.composition.keymaps`:

- `send` = `<C-g>`, bound in normal **and** insert (not an `<Esc>`-like key)
- `close` = `q`, bound in **normal only**, per the rule established for the
  prompt buffer: never take a key in insert mode that the user needs for mode
  transitions or literal text

Closing only hides the window; `bufhidden = hide` means the content is still
there when you reopen. That is the point of the fix.

Because this is a split rather than a float, keybind hints render as a
window-local `statusline` (`send <C-g>  close q`), the same mechanism promoted
output buffers use, gated on the existing `ui.keybind_hints`.

### Configuration

```lua
composition = {
  on_send = nil,          -- fun(text: string): boolean|nil
  clear_on_send = true,
  close_on_send = true,
  separator = "---",
},
ui = {
  composition = {
    height = 0.32,
    min_height = 10,
    max_height = 32,
    keymaps = { send = "<C-g>", close = "q" },
  },
},
```

Behavior under `composition`, presentation under `ui.composition`, matching how
`commands.*` and `ui.*` are already split.

## Dotfiles migration

Full migration, no compatibility shim. `lua/user/prompt_builder.lua` is deleted.

**API consumers:**

| File | Change |
|---|---|
| `user/init.lua` | drop the `prompt_builder.setup()` call |
| `plugins/ai/vantage.lua` | add `composition.on_send` routing to `wiremux.send_text(text .. "\n", { focus = true, submit = true })` |
| `plugins/ai/wiremux.lua` | `open_or_focus` → `vantage.compose()`; `append_text` → `vantage.compose_append()` |
| `snacks/ai_actions.lua` | drop `prompt_builder_buffer_nonempty` and the local `append_entry`; use `vantage.compose_append(entry)` |
| `snacks/ai_context_files.lua` | `append_file_info`/`append_references` → `vantage.compose_append(payload, { separator = false })` |
| `snacks/ai_skills.lua` | `append_text(invocation)` → `vantage.compose_append(invocation, { separator = false })` |

**Detection sites** — all switch to `vantage.is_composition_buffer(bufnr)`:
`blink.lua` (×2), `completion/sources/prompt_files.lua`,
`completion/sources/skills.lua`, and `ai_skills.is_prompt_builder` (which becomes
a thin delegation or is removed in favor of direct calls).

This pulls the previously-deferred `<leader>af*` and `<leader>as` paths into
scope, because they call `append_references` / `append_file_info` /
`append_text` directly. Their *pickers and git logic stay config-side* — only the
destination call changes — so the deferred picker decision is untouched.

`common.format_reference_payload` stays in the config: it is reference
formatting for the config's own pickers, which the non-goals keep config-side.
Optional later cleanup is to have it emit via `vantage.format_reference` to
prevent format drift.

## Testing

New `nvim/tests/spec/composition_spec.lua`:

- append into an empty buffer sets content; append into a non-empty buffer
  inserts the separator; `separator = false` uses blank-line separation only
- **content survives closing the window** — direct regression test for the
  verified `bufhidden = "wipe"` data-loss bug
- the recovery scan finds the buffer while it is hidden
- `compose_send` on empty content warns and does not call `on_send`
- `on_send` receives the trimmed text
- `on_send` returning `false` leaves the content staged
- successful send clears and closes per config
- with no `on_send`, send routes to the `question` backend request
- `compose_clear` empties without destroying the buffer
- `is_composition_buffer` is true inside, false elsewhere
- keymap scoping: `send` in normal and insert, `close` in normal only
- statusline hint present, and absent under `ui.keybind_hints = false`

The dotfiles side has no test infrastructure, so it is verified manually: append
from `<leader>am`, `<leader>af*`, and `<leader>as`; confirm blink `@file` and
`/skill` completion still fires inside the buffer; confirm `<C-g>` reaches
wiremux.

## Sequencing

1. `composition.lua`, config defaults, commands, public API, hints — with tests.
2. README Public API rows, configuration reference, and a Composition section;
   amend the prior spec's superseded non-goal.
3. Dotfiles migration: `on_send` wiring, six API consumers, four detection sites,
   delete `prompt_builder.lua`.

## Implementation amendments

All three phases shipped. Two things differ from the design above.

### 1. Appending must not steal focus (found by end-to-end testing)

The design said nothing about window focus, and the first implementation followed
the dotfiles predecessor in calling `show()` unconditionally — which focuses the
new split. End-to-end testing of the migrated `<leader>af*` and `<leader>am`
paths caught the consequence: after the first append moved the cursor into the
composition buffer, every subsequent action captured its context *from the
composition buffer*, staging `@VantageComposition lines 1-1` instead of
`@mod.lua lines 1-2`.

The predecessor had the same flaw; it was masked in normal use because a human
navigates back to their code between actions, and masked within a single action
because context is captured before the append.

`show(buf, opts)` now takes `opts.focus`, defaulting to **false**. `compose()`
focuses, `compose_append()` does not — staging is something you do *while*
working, so the cursor stays in the file being edited. Two tests cover it
(`compose_append` preserves the current window; `compose` moves to it).

### 2. `compose_send` returns a boolean through every layer

The design implied a boolean but the first pass dropped it in the
`commands.lua` / `init.lua` wrappers, so `vantage.compose_send()` returned nil
and callers could not tell success from failure. Both wrappers now propagate it.

### Testing outcome

Suite went from 113 to 134 tests. The `bufhidden` fix was verified by reverting
it to `"wipe"` and confirming three tests fail exactly as the bug predicts —
`expected "do not lose me" but got ""`, and the recovery scan returning nil.

The dotfiles migration was verified end-to-end against the real plugin: file and
visual-range refs from `ai_context_files` stage with correct paths and blank-line
separation, an `<leader>am` entry appends after a `---` rule, both detection
predicates report true for the composition buffer, and `compose_send` reaches the
configured `on_send` and clears afterward.

### Follow-up not done

`common.format_reference_payload` still lives in the config and formats `@`-refs
independently of `vantage.format_reference`. Both currently emit the same syntax,
but nothing enforces that. Delegating the former to the latter would remove the
drift risk.
