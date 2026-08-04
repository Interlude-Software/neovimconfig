# Neovim Config

Uses [lazy.nvim](https://github.com/folke/lazy.nvim). Plugins install on first launch. External tools must be on `PATH`.

## Requirements

| Tool | Purpose |
|---|---|
| Neovim 0.10+ | |
| Git | lazy.nvim bootstrap |
| [fd](https://github.com/sharkdp/fd) | Telescope `find_files` |
| [ripgrep](https://github.com/BurntSushi/ripgrep) | Telescope `live_grep` — must be a real `rg` binary on `PATH` (a shell alias/function won't do, Telescope spawns `rg` directly) |
| [lazygit](https://github.com/jesseduffield/lazygit) | `<leader>gg` |
| [tree-sitter CLI](https://github.com/tree-sitter/tree-sitter) | nvim-treesitter compiles parsers with it (needs a C compiler too) |
| [.NET SDK 8+](https://dotnet.microsoft.com/download) | Roslyn LSP |
| C/C++ toolchain (clang or gcc) | Building/debugging native code; `clangd` also reads it for system headers |

Mason-managed tools install automatically on first launch (see [First Launch](#first-launch)): `roslyn`, `netcoredbg` (.NET), and `clangd`, `codelldb`, `clang-format` (C/C++).

Optional (format-on-save via conform): [stylua](https://github.com/JohnnyMorganz/StyLua) (Lua), [csharpier](https://csharpier.com/) (C#, `dotnet tool install -g csharpier`). C/C++ uses `clang-format` via Mason.

## Install

**Linux (x86_64):** run the bundled script — installs everything into `~/.local/bin` (no sudo), symlinks the lazygit config, and triggers the Mason tools:
```sh
./scripts/install-linux.sh
```
Make sure `~/.local/bin` (and `~/.dotnet/tools` for csharpier) are on your `PATH`. Distro packages also work, but note Debian/Ubuntu/Mint ship `fd` as `fdfind` (Telescope needs it named `fd`) and may not package `lazygit`.

**macOS:**
```sh
brew install neovim fd ripgrep lazygit dotnet
```

**Windows:**
```powershell
winget install Neovim.Neovim sharkdp.fd BurntSushi.ripgrep.MSVC JesseDuffield.lazygit Microsoft.DotNet.SDK.8 Git.Git
```

Open a new terminal so PATH refreshes.

## First Launch

1. `nvim` (wait for lazy.nvim to finish).
2. Mason auto-installs the required tools in the background (`mason.lua`):
   - `roslyn` — C# LSP
   - `netcoredbg` — .NET debugger for the `coreclr` DAP adapter (`<F5>` → Launch / Attach to .NET Process)
   - `clangd` — C/C++ LSP
   - `codelldb` — C/C++ debugger for the `codelldb` DAP adapter
   - `clang-format` — C/C++ format-on-save

   Watch progress with `:Mason`. If a package is missing, install it manually, e.g. `:MasonInstall clangd codelldb`.
3. Restart.

## Lazygit Config

`lazygit/config.yml` in this repo is the source of truth. Link it into place:

**macOS / Linux:**
```sh
ln -sf ~/.config/nvim/lazygit/config.yml ~/.config/lazygit/config.yml
```

**Windows** (needs Developer Mode or admin):
```powershell
New-Item -ItemType SymbolicLink -Force -Path "$env:LOCALAPPDATA\lazygit\config.yml" -Target "$env:LOCALAPPDATA\nvim\lazygit\config.yml"
```

Or just copy it instead of symlinking.

## Unity Debugging

Uses the `UnityDebugAdapter` from the [VS Code Unity extension](https://marketplace.visualstudio.com/items?itemName=visualstudiotoolsforunity.vstuc) (`visualstudiotoolsforunity.vstuc`). The adapter is auto-discovered via glob, no install needed beyond the extension. Requires .NET SDK 10+.

For standalone builds: enable **Development Build** and **Script Debugging** in Build Settings.

Attach: open a `.cs` file, set a breakpoint (`<leader>db`), press `<F5>`, pick the Unity Editor.

## C / C++

LSP (`clangd`) and debugging (`codelldb`) install via Mason on first launch. clangd resolves include paths from a `compile_commands.json`, `compile_flags.txt`, or `.clangd` in the project root — without one you'll see false errors on system headers. `<leader>bc` generates one for you (the configure step passes `-DCMAKE_EXPORT_COMPILE_COMMANDS=ON`, and clangd finds it under `build/`); otherwise use `bear -- make`. Note that preset-driven projects write it to the preset's binary dir (e.g. `build/macos/`), which clangd does *not* search — symlink it to the project root, or point at it from `.clangd`.

Debug: open a `.c`/`.cpp` file, set a breakpoint (`<leader>db`), press `<F5>`. The C/C++ launch ("Launch C/C++ executable") and attach configs are listed first when the current buffer is native code.

## Building

`<leader>bb` builds the project containing the current buffer, asynchronously and in the background — no separate terminal window. Output is parsed with `errorformat` into the quickfix list and, when the build fails, Trouble opens with the diagnostics; `<CR>` jumps to an error, `]q` / `[q` step through them. The statusline shows a spinner while building and `✗ 3 E 0 W` or `✓ proj 1.4s` when it settles.

The project is found by walking up from the current file: a `CMakeLists.txt` means `cmake --build`, falling back to `make`. Starting a build while one is running replaces it, so you can just keep hitting `<leader>bb`.

**Projects with `CMakePresets.json` are driven through their presets** — `cmake --build --preset <name>`, and `cmake --preset <name>` to configure. This matters for anything using vcpkg or a custom toolchain: the preset carries the toolchain file and the real binary dir (often `build/<presetName>`, not `build/`). Configuring such a project by hand writes a toolchain-less cache into `build/` that then *looks* configured. `cmake` itself decides which presets are valid on this host, so a Linux-or-Windows-only preset is never offered.

`<leader>bp` picks the preset when a project defines more than one; the choice persists per project in `stdpath("cache")/nvim_build_preset.json`. Without a choice, the first preset cmake reports is used, and `vim.g.build_preset` overrides everything.

Projects with no presets configure themselves on first use into the first of `build/`, `out/build/`, `cmake-build-debug/`, `cmake-build-release/` that already holds a `CMakeCache.txt` (creating `build/` if none do).

Link errors, missing tools, and CMake failures that no `errorformat` pattern captures still show up — the notification points you at `<leader>bo`, which dumps the raw output in a split.

To override detection entirely, set `vim.g.build_command` (a string run through the shell, or an argv list) plus optionally `vim.g.build_cwd`. `vim.g.build_jobs` sets parallelism (defaults to the CPU count) and `vim.g.build_dirs` replaces the build-directory candidates.

| Key | Action |
|---|---|
| `<leader>bb` | Build |
| `<leader>bl` | Re-run last build (ignores current buffer) |
| `<leader>bB` | Clean rebuild |
| `<leader>bc` | CMake configure + build |
| `<leader>bC` | CMake configure only |
| `<leader>bp` | Pick the CMake preset for this project |
| `<leader>bo` | Raw output of the last build |
| `<leader>bx` | Cancel the running build |
| `]q` / `[q` | Next / previous quickfix entry |

## Running

`<leader>br` picks a **run profile** — a named set of command-line arguments for one of the project's built executables — and launches it, most-recently-run first. `<leader>bR` re-launches the top one without asking.

Profiles live in `.nvim-run.json` at the project root, so they are committed and travel with the repo. `<leader>bn` creates one through prompts; `<leader>be` opens the file for hand-editing. Recency ordering is deliberately *not* stored there — it lives in `stdpath("cache")` so launching something never dirties your working tree.

```json
{
  "profiles": [
    { "name": "Host",     "args": ["--seed", "42"] },
    { "name": "Client",   "args": ["--connect", "127.0.0.1", "--window-index", "1"] },
    { "name": "Headless", "args": ["--headless", "--log-level", "verbose"], "filter": "warn" }
  ]
}
```

Per-profile keys: `args`, and optionally `exe` (relative to the project root — omit it and the newest executable under the build dir's `bin/` is used), `cwd` (**defaults to the project root**, since a game in development resolves `assets/`/`scripts/` relative to the repo, not to the binary), `env`, and `filter` (the log level the window opens at).

**Several runs can be live at once** — launch `Host` and `Client` and each gets its own log window. `<leader>bg` jumps between them, `<leader>bk` stops one or all. Anything still running is killed when you quit nvim, so no stray processes.

### Log window

Output is captured and parsed for a `[tag] [LVL] message` shape (`ERR`/`WRN`/`INF`/`VRB`); the level token and tag are highlighted, and the winbar shows live error/warning counts. Note that programs which colour output only for a tty (a common pattern) emit clean text here, since the capture is a pipe rather than a terminal.

| Key | Action (inside the log window) |
|---|---|
| `e` | Errors only |
| `w` | Errors + warnings |
| `a` | Everything |
| `f` | Toggle follow (tailing) |
| `r` | Restart this run |
| `x` | Stop this run |
| `q` | Close the window |

Following is automatic: scrolling back pauses tailing, returning to the last line resumes it.

| Key | Action |
|---|---|
| `<leader>br` | Pick and launch a run profile |
| `<leader>bR` | Re-launch the most recent profile |
| `<leader>bn` | New run profile (prompts) |
| `<leader>be` | Edit `.nvim-run.json` |
| `<leader>bg` | Go to a run's log window |
| `<leader>bk` | Stop a run (or all) |

`:Run` with no argument is the picker; `:Run <name>` launches a profile directly and tab-completes.

## Keymaps

Leader: `<Space>`

### Telescope
| Key | Action |
|---|---|
| `<C-p>` / `<leader>ff` | Find files |
| `<leader>fg` | Live grep |
| `<leader>fb` | Buffers |
| `<leader>fh` | Help tags |
| `<leader>fc` | Live grep C# only |

### LSP (`.cs` / `.c` / `.cpp`)
| Key | Action |
|---|---|
| `gd` | Go to definition |
| `<leader>gd` | Go to definition (vsplit) |
| `K` | Hover |
| `gr` | References |
| `<leader>rn` | Rename |
| `<leader>ca` | Code actions |

### Git
| Key | Action |
|---|---|
| `<leader>gg` | LazyGit |

### Debug (`.cs` / `.c` / `.cpp`)
| Key | Action |
|---|---|
| `<leader>db` | Toggle breakpoint |
| `<F5>` / `<leader>dc` | Continue / attach |
| `<F10>` | Step over |
| `<F11>` | Step into |
| `<F12>` | Step out |
| `<leader>du` | Toggle UI |

### Build / Run (see [Building](#building), [Running](#running))
| Key | Action |
|---|---|
| `<leader>bb` | Build current project |
| `<leader>bp` | Pick CMake preset |
| `<leader>bo` | Raw build output |
| `<leader>bx` | Cancel build |
| `<leader>br` | Pick and launch a run profile |
| `<leader>bg` | Go to a run's log |
| `<leader>bk` | Stop a run |
| `]q` / `[q` | Next / previous quickfix entry |

### Misc
| Key | Action |
|---|---|
| `<leader>u` | Undotree |
