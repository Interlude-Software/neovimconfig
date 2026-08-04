# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A personal Neovim configuration centered on **Unity / C# development**. There is no build or test suite — "running" it means launching `nvim` and letting [lazy.nvim](https://github.com/folke/lazy.nvim) sync plugins. Changes are validated by editing config, restarting Neovim, and observing behavior.

## Architecture

- `init.lua` — sets `<Space>` as leader **before** anything else (keymaps depend on it), bootstraps lazy.nvim, applies core `vim.opt` settings, then `require("lazy").setup("plugins")`.
- `lua/plugins/*.lua` — lazy.nvim auto-imports every file in this directory. **Each file returns a single plugin spec table** (one plugin per file). Adding a plugin = adding a new file here; no central registry to update.
- `lua/user/*.lua` — non-plugin modules, wired up by hand from `init.lua` (they cannot live in `lua/plugins/`, which lazy would try to read as specs). Currently just `build.lua`.
- `lazy-lock.json` — pinned plugin commits (committed; this is the lockfile).
- `lazygit/config.yml` — source of truth for the lazygit config, symlinked into place per the README (not auto-loaded by Neovim).

### Conventions for plugin specs

- LSP keymaps and capabilities are attached in each LSP plugin's `on_attach` (see `roslyn.lua`), not globally.
- Lazy-loading is deliberate: specs use `ft = "cs"`, `event = ...`, `cmd = ...`, or `keys = ...`. Preserve these triggers when editing — loading eagerly will slow startup and can break load order.
- Unity/.NET junk directories (`Library`, `Temp`, `Logs`, `obj`, `bin`, `UserSettings`, `CodeCoverage`) are filtered in **three independent places** that must be kept in sync: `telescope.lua` (`file_ignore_patterns`, `find_files` fd args, and `live_grep` ripgrep globs) and `neo-tree.lua` (`hide_by_name`).

### C# / Unity stack (the core of this config)

- **LSP**: `roslyn.nvim` (`roslyn.lua`), not lspconfig's omnisharp. Installed via Mason — `mason.lua` adds the `Crashdummyy/mason-registry` registry specifically to make the `roslyn` package available. First-time setup requires `:MasonInstall roslyn` then a restart.
- **Debugging** (`dap.lua`, the most involved file): uses the `UnityDebugAdapter.dll` from the VS Code "Visual Studio Tools for Unity" extension (`visualstudiotoolsforunity.vstuc`), auto-discovered via glob under `~/.vscode/extensions/`. Also configures `coreclr` (netcoredbg, via Mason) for plain .NET. The Unity attach flow discovers running Editors by scanning `lsof` for listening ports on `127.0.0.1:56xxx`, maps PIDs to project paths via `ps`/`-projectPath`, caches the last project to `stdpath("cache")/unity_debug_project.txt`, and dynamically builds the dap config list (a "Re-attach" entry appears only when a cached project exists). The Unity port-discovery logic is Unix-specific (`lsof`/`ps`/`pgrep`).
- **Formatting**: `conform.nvim` formats on save — `stylua` for Lua, `csharpier` for C#, `clang-format` for C/C++, LSP fallback otherwise.
- **Completion**: `nvim-cmp` (nvim_lsp + buffer sources). Copilot inline suggestions are separate (`copilot.lua`, `<C-l>` to accept).

### C / C++ stack

- **LSP**: `clangd`, configured in `lspconfig.lua` (which owns `nvim-lspconfig`). Lazy-loaded on `ft = { c, cpp, objc, objcpp, cuda }`; the `on_attach` keymaps mirror `roslyn.lua` exactly. Install via Mason: `:MasonInstall clangd`. clangd reads `compile_commands.json` (or `.clangd`/`compile_flags.txt`) from the project root for include paths.
- **Building**: `lua/user/build.lua` — async `cmake --build` / `make` via `vim.system`, output parsed into the quickfix list with a custom `errorformat` (appended to the built-in one) and surfaced through Trouble. Keymaps are under `<leader>b`, registered by `M.setup()` from `init.lua`; the statusline component is consumed by `lualine.lua`. Two details are load-bearing: output is line-buffered per stream (chunks split mid-line would parse as bogus entries), and `valid == 0` entries are filtered out after parsing (unmatched build chatter would otherwise fill the list). Multi-line linker/CMake messages are folded with `%+C` and flattened to one line.
  - **Presets take priority over build-dir probing.** When a `CMakePresets.json` exists, the build runs `cmake --build --preset <name>`; the host-valid preset list comes from shelling out to `cmake --list-presets` (so `condition` gates are evaluated by cmake, not reimplemented), and `binaryDir` is resolved through the `inherits` chain with `${sourceDir}`/`${presetName}` expanded. Probing for `build/CMakeCache.txt` on such a project finds the wrong directory and, worse, a bare `cmake -B build` leaves a toolchain-less cache behind that looks configured — this bit the zombiegamenative (vcpkg) project during development.
- **Running**: `lua/user/run.lua` — launches built executables with saved argument profiles from `.nvim-run.json` at the project root, streaming each run's output into its own log buffer (filterable by `[LVL]`). Several runs are supported concurrently, keyed by id in a `runs` table. It locates executables via `build.binary_dir()` rather than probing itself, so the preset resolution has exactly one home. Three non-obvious choices: recency ordering lives in `stdpath("cache")`, never in the committed profile file (launching would otherwise dirty the tree); `cwd` defaults to the project root, not the exe's directory, because game data resolves relative to the repo; and buffer appends are batched on a 60ms timer, since a verbose program emitting thousands of lines a second will stall the editor if each line touches the buffer. `vim.json.encode` turns an empty Lua table into `{}`, so profile arrays are serialised by hand.
- **Profile form**: `lua/user/form.lua` — a small field form in a floating window (`section`/`text`/`int`/`bool`/`enum`), used by `run.lua` to build run profiles. Two contracts matter: `on_submit` runs *before* the window closes and returning `false` keeps it open (closing first would discard everything typed whenever a save is rejected), and `required`/`int` validation happens in the form so the message can name the field. The label column is sized to the longest label at render time — a fixed width collided with the value column.
  - The option schema lives in the same `.nvim-run.json` under `options` and is maintained by hand; nothing can interrogate a binary for its real flags. `save_profiles` must round-trip `options`, or saving a profile silently deletes the definitions the form is generated from. Profile `args` stay a plain list so hand-editing works: opening a profile parses the list back against the schema and keeps anything unrecognised in an "Extra args" field instead of dropping it.
- **Debugging**: `codelldb` (Mason) adapter in `dap.lua`. `build_configs()` adds "Launch C/C++ executable" and "Attach to process (C/C++)" entries, surfaced first when the current buffer's filetype is `c`/`cpp` and appended otherwise. Install via Mason: `:MasonInstall codelldb`.

### treesitter note

`treesitter.lua` targets the new nvim-treesitter v1.x API (no `configs.setup()`; highlighting is automatic). It contains a **compatibility shim** re-adding `parsers.ft_to_lang`, which telescope still calls but v1.x removed. Don't delete this shim without confirming telescope no longer needs it.

## External dependencies

Plugins install on first launch; external CLIs must be on `PATH`. See the README for the full table and per-OS install commands. Key ones: `fd` + `ripgrep` (telescope), `lazygit`, `.NET SDK 8+` (roslyn) / `10+` (Unity debug adapter), `tree-sitter` CLI + a C compiler (parser builds), `Node.js 22+` (Copilot — older Node is rejected at startup), `stylua` + `csharpier` (formatting).

## Keymaps

Leader is `<Space>`. Full table is in the README. The which-key groups (`<leader>d` debug, `<leader>x` trouble, `<leader>r` rename, `<leader>c` code action) are declared in `which-key.lua`.
