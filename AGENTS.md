# Project Agent Instructions

## Lua API Requirement

Every user command must have a corresponding public Lua function exposed through `require("vantage")`. The command is a thin wrapper; the Lua function is the real implementation. This ensures integrations (statusline, keymaps, other plugins) can invoke any Vantage behavior without shelling out to `:Vantage*` commands.

Pattern:
- `lua/vantage/init.lua` — public function (e.g. `M.explain(opts)`)
- `lua/vantage/commands.lua` — user command calls the public function
- `lua/vantage/command_names.lua` — command name string

When adding a new command, add all three in the same change. Do not add a command that only exists as a `vim.api.nvim_create_user_command` without a Lua entry point.

## Documentation Guardrail

Keep the public API documentation in `README.md` current with code changes.

Whenever you add, remove, rename, or change behavior for any public Vantage surface, update the `README.md` **Public API** section in the same change. This includes:

- user commands in `lua/vantage/command_names.lua` or `lua/vantage/commands.lua`
- command modes/range support (`normal`, range, visual via `:'<,'>`)
- prompt behavior, including whether a command requires inline args or opens the prompt buffer
- agent/session/tool availability for each command and function, including read-only tools and Vantage submit tools
- public Lua APIs exposed from `lua/vantage/init.lua`
- keymaps/config that affect public command behavior

Before calling the work complete, run a quick documentation consistency check, for example:

```bash
rtk rg -n "Vantage[A-Za-z]+|function M\." lua/vantage README.md
```

If command behavior, public Lua API, or agentic tool availability changes but the README Public API tables do not change, treat that as documentation rot and fix it before finishing.

## Lua Test Layout

The Lua suite is one module per subject under `nvim/tests/spec/`, sharing a
registry (`nvim/tests/support/harness.lua`) and fixtures
(`nvim/tests/support/helpers.lua`). `nvim/tests/vantage_spec.lua` is only an
aggregator: it requires every spec module, then runs.

When adding Lua tests:

- Put the test in the spec module for the command or module under test. Do not
  add tests to `vantage_spec.lua` — it holds no tests.
- New subject: create `nvim/tests/spec/<name>_spec.lua` and add `"<name>"` to the
  `SPECS` list in `vantage_spec.lua`.
- New shared fixture: add it to `support/helpers.lua` and export it in the table
  at the bottom, then localize it in the spec modules that use it.
- Keep a spec module focused. When one grows past roughly 300 lines it is usually
  covering more than one concern and should be split (as `annotation_spec.lua`
  was split into command / render / status).

Headless-mode caveat worth knowing before writing UI tests: some mode
transitions cannot be driven synchronously. The prompt buffer's `startinsert`
runs inside `vim.schedule()` and only takes effect once Neovim next reads input,
so a synchronous test can never observe insert mode and `vim.wait` does not help
— assert the buffer's keymap table instead. Visual mode, by contrast, works:
`vim.cmd("normal! vjj")` establishes a real selection and stays in visual mode.
