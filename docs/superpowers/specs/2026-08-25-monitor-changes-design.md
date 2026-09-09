# Monitor Changes Mode

Status: approved, partially superseded
Date: 2026-08-25

> **Read the revision at the end of this document first.** The sections below
> describing a floating follow window, its cycle keymaps, and
> `:VantageMonitorFocus` describe the original design and no longer match the
> code. The detection half (git polling, the ring, self-write suppression) is
> unchanged and still current.

## Purpose

A toggleable live review feed for edits made to the workspace by something other
than this Neovim instance -- in practice, an AI agent running in an adjacent
pane. When a file changes on disk, a centered float shows it with the cursor on
the first changed hunk, so you can watch an agent's work land without
alt-tabbing or hunting through `git status` yourself.

The mode is explicitly *not* a general file watcher, a diff viewer, or a
worklist. It is a feed you glance at.

## Superseded non-goal

`2026-08-25-prompt-building-public-api-design.md` and
`2026-08-25-composition-buffer-design.md` both state:

> **Vantage does not own git plumbing.** Ref sources like git tracked / changed /
> branch-diff / conflicts remain config-side. Vantage never shells out to git to
> build a file list.

This design supersedes that **narrowly and deliberately**. Vantage gains exactly
two git invocations, both confined to `monitor_source.lua`:

- `git status --porcelain --untracked-files=all` to detect changes
- `git diff -U0 -- <path>` to locate the first hunk in the file being displayed

The boundary the non-goal protected is preserved by making detection a seam:
`monitor.source` accepts any `fun(root): { poll = fun(cb) }`, and the git
adapter is merely the shipped default. Reference pickers remain config-side and
are untouched by this change.

README's "Vantage commands are explicit" stance also relaxes here: this is the
first vantage surface that renders without a direct invocation. It is bounded by
being opt-in per session, off by default, and self-terminating when its window
closes.

## Approaches considered

**Per-directory `fs_event` fleet (rejected).** 453 watchers on this monorepo,
instant notification. Rejected because it needs git anyway to seed and refresh
the directory set, burns one fd per directory, must rebuild when the agent
creates a directory, and delivers raw filesystem events including gitignored
paths -- forcing a hand-rolled reimplementation of gitignore filtering that git
already performs. Recursive `fs_event` would avoid the fleet but is unavailable
on Linux, where inotify has no recursive mode.

**Config-side file list (rejected).** Honors the non-goal exactly and mirrors how
reference pickers stayed config-side, but ships a feature that does nothing until
wired up.

**Async `git status` poll (chosen).** One off-thread subprocess per tick (~89ms
on this repo, invisible via `vim.system`). New files, deletions, and gitignore
filtering all come free because git already computes them. No fds, no watcher
fleet, portable. Cost: change latency is bounded by the poll interval rather
than instantaneous, which is acceptable for a feed you glance at.

## Modules

Three modules, mirroring `history`'s existing split of pure core / storage seam
/ UI.

### `lua/vantage/monitor.lua`

Mode lifecycle, the change ring, cycle arithmetic, and self-write suppression.
Knows nothing about windows, buffers, or git.

```
M.toggle()            -- the only thing the command calls
M.start() / M.stop()
M.is_active(): boolean
M.entries(): Entry[]  -- newest-first, for tests and the picker
M.cycle(direction)    -- "older" | "newer"
M._set_source(s)      -- test seam, mirrors history._set_store
```

`Entry` is `{ path, status, mtime, at }` where `status` is the porcelain code
and `at` is `os.time()`.

### `lua/vantage/monitor_source.lua`

The detection seam.

```
M.git(root): { poll = fun(cb: fun(changed: Change[])) }
M.fake(ticks): { poll = ... }   -- test double, mirrors history_store.fake
M.first_hunk(root, path, cb)    -- git diff -U0, returns a 1-indexed line
```

The only module in vantage that invokes git.

### `lua/vantage/ui/follow_window.lua`

The centered float, the default `render`, and the cycle keymaps.

Keymaps live here rather than in a separate module -- unlike `history_keymap`,
which needed its own module because it attaches to buffers it does not own.
These bind only to whatever buffer the float currently holds.

## Data flow

```
timer(interval_ms)
  -> source.poll(cb)                   -- vim.system, off-thread
  -> parse porcelain -> {path, status}[]
  -> fs_stat each for mtime
  -> diff vs previous snapshot         -- new path OR mtime advanced
  -> drop paths this nvim wrote within self_write_grace_ms
  -> push onto ring (newest-first, capped, deduped by path)
  -> if not pinned: render(newest)
```

Deduping by path means a file edited three times occupies one ring slot and
moves to the front. The ring is "recently changed files", not "every write
event" -- which is what you want to cycle through.

The mtime comparison closes `git status`'s blind spot: a file already reported
modified stays modified, so status alone cannot reveal a second edit. Only the
reported paths are stat'd, typically a handful rather than the whole tree.

## Known characteristics

**The baseline is established asynchronously.** `start()` fires a seeding poll
immediately, but that poll is a subprocess and completes roughly one `git
status` later (~90ms on a large repository). A change landing inside that window
is absorbed into the baseline rather than emitted as an event. This is inherent
to having a baseline at all -- any baseline taken at time T makes everything
before T "already there" -- and the window is short relative to the mode's
actual use, where it is toggled on before an agent is given work.

## Configuration

Behavior and presentation split across two tables, following the `composition`
precedent.

```lua
monitor = {
  interval_ms = 1000,
  limit = 50,
  self_write_grace_ms = 2000,
  source = nil,   -- fun(root): { poll = fun(cb) }; nil = git default
  render = nil,   -- fun(entry, win); nil = open file, jump to first hunk
},
ui = {
  monitor = {
    width = 0.8,
    height = 0.8,
    border = "rounded",
    keymaps = { prev = "<Up>", next = "<Down>", close = "q" },
  },
},
```

No `enabled` flag: the mode is off until toggled, so a kill switch would be a
second way to say the same thing.

`render` exists so a future optional diff view is config-supplied and vantage
never names a diff plugin. The shipped default opens the file and jumps to the
first hunk.

## Command surface

Per AGENTS.md, registered in `command_names.lua`, wrapped in `commands.lua`,
exported from `init.lua`, and documented in README's Public API in the same
change.

| Command | Function | Behavior |
|---|---|---|
| `VantageMonitor` | `vantage.monitor()` | Toggle the mode |
| `VantageMonitorFocus` | `vantage.monitor_focus()` | Focus the follow float |

## Window behavior

**The float does not take focus when it renders.** The follow window holds a
*real file buffer*; if focus jumped there mid-keystroke, the next characters
typed would land in the file the agent is editing. Render never moves the
cursor out of the user's window. Interaction requires deliberate focus via
`vantage.monitor_focus()`.

**No buffer options are ever set on the displayed buffer** -- only window
options. Setting `modifiable = false` to make the feed "safe" would be a trap
for the same reason the keymaps are: buffers are global, so it would make the
file read-only in the user's main window too. The float applies
`win_util.apply_readable_options` and leaves the buffer exactly as Neovim
loaded it.

**Pinning.** Cycling backward sets an index and pins the float; incoming changes
accumulate in the ring without moving what is being read. Stepping forward past
newest clears the index and resumes live follow -- `history.cycle`'s shape minus
the draft restore.

**Unsaved buffers are never reloaded.** If a changed path is already open and
`vim.bo[buf].modified` is true, the float displays it without reloading and
marks the footer, so it is visible that the float shows the user's version
rather than the agent's. Reloading would discard the user's edits; silently
showing stale content without saying so would be worse.

**Deletions** get a ring entry like anything else, rendered as a short scratch
message rather than a file. Opening a deleted path would either error or create
an empty buffer indistinguishable from real content.

### The keymap problem

The float displays a real file buffer and Neovim buffers are global, so a
buffer-local `<Up>` binding would follow that buffer into the user's main window
and break arrow navigation in a file they are editing. Neovim has no
window-local keymaps.

Resolution: bind buffer-locally, guard on the current window being the follow
window, and fall through otherwise.

```lua
vim.keymap.set("n", lhs, function()
  if vim.api.nvim_get_current_win() ~= follow_win then
    -- "n" = no remap, so this cannot re-enter this mapping
    return vim.api.nvim_feedkeys(vim.keycode(lhs), "n", false)
  end
  step("older")
end, { buffer = buf })
```

The binding then behaves as if unmapped everywhere except the follow window,
making `<Up>`/`<Down>` safe defaults consistent with history's cycling idiom.
Bindings are removed when a buffer is swapped out of the float, so cleanup is
deterministic -- `render` is the only thing that ever swaps it.

## Lifecycle

`stop()` closes the timer (`timer:stop()` then `timer:close()`, since an
unclosed uv handle leaks), closes the float, removes the cycle keymaps from
whatever buffer currently holds them, and clears the ring. It is called by the
toggle, by the close keymap, and from a `VimLeavePre` autocmd -- the same guard
`composition.lua` uses.

**Closing the window stops the mode.** Leaving it polling invisibly and
re-opening on the next change would reintroduce the auto-appearing behavior
deliberately removed from composition.

**Self-write suppression** is a `BufWritePost` autocmd recording
`path -> timestamp`. A polled change whose path was written by this instance
within `self_write_grace_ms` is dropped. The table is pruned each tick so it
cannot grow unbounded across a long session.

## Error handling

Consistent with `history`: the mode is a convenience and must never break the
editor.

- Each distinct failure notifies once per session (`warn_once`), so a broken
  repo cannot produce a notification storm on every tick.
- A non-zero `git status` exit (not a repository, git absent) stops the mode
  with one notification rather than retrying forever.
- A failed `git diff -U0` degrades to cursor at line 1; hunk position is an
  enhancement, not a precondition for showing the file.
- Poll callbacks are wrapped so a raising `source` or `render` stops the mode
  cleanly rather than leaving an orphaned timer.
- `vim.system` is called with the workspace root as `cwd`, never by
  interpolating paths into a shell string.

## Testing

New spec modules under `nvim/tests/spec/`, registered in `vantage_spec.lua`'s
`SPECS`, one module per subject per AGENTS.md.

`monitor_spec.lua` -- ring and lifecycle, driven through `monitor._set_source`
with `monitor_source.fake`:
- dedupes by path, moving a re-edited file to the front
- applies `limit`
- `cycle("older")` pins; returning to newest resumes live follow
- `cycle` at either end is a no-op rather than wrapping
- `stop()` clears the ring and reports inactive
- a path written by this instance within the grace window is dropped
- the same path written outside the grace window is kept

`monitor_source_spec.lua` -- parsing, against a real temp git repo:
- porcelain parsing covers modified, added, untracked, and deleted
- `first_hunk` returns the first changed line for a modified file
- `first_hunk` degrades to nil rather than raising outside a repository

`follow_window_spec.lua` -- window behavior:
- render does not move focus out of the current window
- cycle keymaps are bound on the displayed buffer and removed on swap
- the guard falls through when the current window is not the float
- a modified buffer is displayed without being reloaded
- no buffer options are mutated on the displayed buffer

Test doubles use `monitor_source.fake`, so no spec spawns git except
`monitor_source_spec.lua`, which builds its own temp repository.


---

## Revision, 2026-08-26: native navigation replaces the float

The float was wrong. It reinvented a mechanism the editor already had, and paid
for it twice over: a window holding a real file buffer that must never take
focus, and cycle keymaps that shadowed the user's arrow keys in that buffer.

**Superseded by:** the default renderer opens the changed file in the current
window with a plain `:edit`. Vim records that as a jump, so `<C-o>` / `<C-i>`
walk the trail of recent edits natively. Monitor mode binds nothing.

Removed outright, per roll-forward:

- `lua/vantage/ui/follow_window.lua` — the float, its footer, its keymaps, and
  the guarded fall-through those keymaps needed
- `:VantageMonitorFocus` / `vantage.monitor_focus()` — a float-only affordance
- `monitor.cycle()` / `monitor.cursor()` and pinning — the jumplist supersedes
  the ring cursor
- the entire `ui.monitor` config block (geometry, border, keymaps)

Replaced by `lua/vantage/ui/navigate.lua`, which is one function.

### Contract change

`render(entry, index, total)` becomes `render(context)`, a single table:

```lua
---@class MonitorRenderContext
---@field path string      absolute path to the changed file
---@field status string    two-character git porcelain code
---@field workspace string workspace root being watched
---@field line integer?    first changed line, nil when unknown
---@field deleted boolean  the path no longer exists
```

A table rather than positional arguments because the diff-view case will want
more than a path, and a positional signature makes every added field a breaking
change for renderers already in the wild. `monitor.on_stop` joins it, for a
custom renderer that opened something it must close.

`first_hunk` moves from a free function onto the source (`source.first_hunk(path,
cb)`), so a custom `monitor.source` can supply its own notion of where a change
is — or omit it, in which case the renderer gets `line = nil`.

### Behavior changes

**Every change in a burst renders, oldest first**, rather than only the newest.
The trail is the feature: rendering only the last change would leave a single
jumplist hop instead of a walkable history. Hunk lookups are drained
sequentially for the same reason — racing them would scramble the trail into an
order the files never changed in.

**Navigation happens only in normal mode.** Swapping the buffer out from under
someone mid-insert would send their next keystrokes into the file the agent is
editing. The change still enters the ring, so `monitor_entries()` still sees it.

**Pinning is gone.** It existed so a burst could not yank the float away from
what you were reading. `<C-o>` covers that case natively and does not need a
mode to remember it.


---

## Revision, 2026-08-26: overlapping polls exhausted the system file table

A timer-driven poll with no in-flight guard is a subprocess leak, not merely a
performance concern. The original design polled on a fixed interval and never
asked whether the previous poll had finished.

**Measured**, at a 20ms interval against a source that never answered: 29 polls
stacked in 600ms. With the real git adapter and an artificially slow `git status`
(1s per call, 20ms interval, 3s run) the contrast is starker still:

| | git invocations |
|---|---|
| without in-flight guard | 156 |
| with in-flight guard | 3 |

Each of those is a live subprocess holding pipe file descriptors. Several editor
sessions running the mode for a few minutes drained this machine's file table,
after which unrelated commands failed with `Too many open files in system` --
which is how the bug was found.

The failure mode is not exotic. Any repository where `git status` takes longer
than `interval_ms` reaches it: a large monorepo, a cold cache, a network
filesystem, or simply a low configured interval.

### Fix

**An in-flight guard.** A tick whose predecessor is still running returns
without issuing a poll. This alone bounds concurrency at one, whatever the
interval or repository size, and it degrades gracefully: a slow repository is
simply polled less often than configured.

**Killing, not just forgetting.** `monitor.poll_timeout_ms` (default 30000)
bounds how long an unanswered poll may hold the guard before it is abandoned, so
a `git status` wedged on an unresponsive filesystem cannot silence the mode
permanently. Abandoning kills the subprocess -- dropping only the callback would
leave the process and its pipes alive for the rest of the session. `poll` now
returns its handle for exactly this reason, and `stop()` kills any poll still in
flight.

The timeout is generous on purpose. The guard already prevents stacking, so the
timeout only has to rescue a poll that will *never* answer; a short value would
abandon slow-but-healthy polls on a large repository and never see their
results.

**A per-poll sequence number.** An abandoned poll that answers late must not be
mistaken for the live one -- without this it would repopulate the ring and render
from a poll the mode had already given up on. The existing generation token is
not sufficient: it distinguishes runs, not polls within a run.

### Testing note

No spec drives the mode against real git on a timer; `monitor_source_spec` calls
`poll()` directly, once, with a bounded wait. Every other spec uses a fake or
inline source. That keeps the suite itself incapable of the stacking this
revision fixes, independently of whether the guard is present.
