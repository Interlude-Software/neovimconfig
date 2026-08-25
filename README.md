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

Profiles live in `.nvim-run.json` at the project root, so they are committed and travel with the repo. Recency ordering is deliberately *not* stored there — it lives in `stdpath("cache")` so launching something never dirties your working tree.

### The profile form

`<leader>bn` opens a form rather than asking you to type an argument string; `<leader>be` reopens an existing profile in it. Checkboxes for flags, typed fields for values, and a live preview of the exact command at the bottom:

```
╭──────────────── New run profile ─────────────────╮
│   Profile                                        │
│       Name                Client                 │
│                                                  │
│   Flags                                          │
│   [ ] Headless                                   │
│   [x] Wait for enter                             │
│                                                  │
│   Values                                         │
│       Seed                42                     │
│       Connect to          127.0.0.1              │
│       Log level           < verbose >            │
│                                                  │
│   Advanced                                       │
│       Extra args          (none)                 │
│       Executable          (auto-detect newest)   │
│       Working dir         (project root)         │
│       Log filter          < all >                │
│                                                  │
│   → zombiegame --wait-for-enter --seed 42 ...    │
╰─ <CR> edit  <Space> toggle  <C-s> save  q cancel ╯
```

| Key | Action |
|---|---|
| `j` / `k`, `<Tab>` / `<S-Tab>` | Move between fields (headings are skipped) |
| `<CR>` | Edit: toggle a checkbox, prompt for a value, pick from an enum |
| `<Space>` | Toggle a checkbox, or cycle an enum without a picker |
| `<C-s>` | Save |
| `q` / `<Esc>` | Cancel |

Integer fields are checked on save, and a rejected save leaves the form open with your input intact.

`<CR>` on **Executable** opens a picker of every executable found under the build tree, newest first, with size and age — no path typing:

```
  (auto-detect newest built executable)
  build/macos/bin/zombiegame   17.2 MB, 4m ago
  build/macos/bin/tools/packer  1.1 MB, 2h ago
  Enter a path manually…
```

Paths are stored relative to the project root. The list is gathered when you open the field, so a build finishing while the form sits open shows up. It searches two levels under the build directory (skipping `CMakeFiles/`), which is wider than auto-detect looks — auto-detect stays narrow so it cannot start picking a test harness just because it is newer.

### The option schema

The form is generated from an `options` array in the same file — **this is maintained by hand**, since nothing can interrogate an executable for its real flags. `<leader>bE` opens the raw JSON to edit it (and scaffolds a starter file if there is none).

```json
{
  "options": [
    { "flag": "--headless",    "type": "bool",   "label": "Headless" },
    { "flag": "--seed",        "type": "int",    "label": "Seed" },
    { "flag": "--connect",     "type": "string", "label": "Connect to" },
    { "flag": "--log-level",   "type": "enum",   "label": "Log level",
      "values": ["error", "warning", "info", "verbose"] }
  ],
  "profiles": [
    { "name": "Host",   "args": ["--seed", "42"] },
    { "name": "Client", "args": ["--connect", "127.0.0.1", "--window-index", "1"] }
  ]
}
```

#### Keeping it in sync

The schema drifts as soon as you add a flag to the program, and nothing else will tell you. `<leader>bf` (or `:RunScanFlags`) greps the source for quoted `--flag` literals and diffs them against the schema: anything missing lands in the quickfix list, jumpable to the line that uses it, and schema entries no longer found in the source are reported as possibly stale. `:RunScanFlags!` appends the missing ones and opens the file so you can check them.

Types are guessed from context — a flag followed by `argv[++i]` is a value, one with `atoi`/`stoi`/`strtoul` on the same line is an `int`, a bare comparison is a switch. **Review what it adds**: it is a grep, not a parser, so it cannot see flags built by string concatenation and it never invents `enum` values.

Types: `bool` renders a checkbox and contributes a bare flag; `int` is validated on save; `string` is free text; `enum` cycles through `values`. `label` is what the form shows — omit it and the flag is used.

Arguments are stored as a plain list, so hand-writing them still works. Opening such a profile in the form parses the list back against the schema, and **anything the schema does not describe is preserved** in the "Extra args" field rather than being dropped. Saving rewrites arguments in schema order. A project with no `options` still gets a working form — just Name plus Extra args.

Per-profile keys beyond `args`: `exe` (relative to the project root — omit it and the newest executable under the build dir's `bin/` is used), `cwd` (**defaults to the project root**, since a game in development resolves `assets/`/`scripts/` relative to the repo, not to the binary), `env`, and `filter` (the log level the window opens at).

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
| `<leader>bP` | Pick and launch a run profile under `samply record` |
| `<leader>bR` | Re-launch the most recent profile |
| `<leader>bn` | New run profile (form) |
| `<leader>be` | Edit a run profile (form) |
| `<leader>bE` | Edit `.nvim-run.json` (raw, for the option schema) |
| `<leader>bg` | Go to a run's log window |
| `<leader>bk` | Stop a run (or all) |
| `<leader>bf` | Scan the source for flags missing from the schema |

`:Run` with no argument is the picker; `:Run <name>` launches a profile directly and tab-completes. `:Run!` (or `<leader>bP`) records the run with [samply](https://github.com/mstange/samply) (`brew install samply`) and opens the Firefox Profiler UI when the game exits — **quit the game normally** rather than killing it. Signalling samply mid-recording loses the capture, so `<leader>bk` on a profiled run stops the *game* and lets samply finish; a second `<leader>bk` closes samply's profile server. Profile a `RelWithDebInfo`/`Release` build if you care about the numbers.

## Reviewing changes

`<leader>gr` (or `:GitReview`) opens every changed file as a normal buffer with the diff rendered **inline**: changed lines highlighted, removed lines shown as virtual lines where they used to be, and intra-line edits word-diffed. It is the same text you would read in lazygit's diff pane, except it is a real buffer — LSP, `gd`, folds and editing all still work, and `<leader>hs` stages the hunk under the cursor without leaving the file.

Every hunk in the review also goes into the quickfix list, so `]q` / `[q` walks the whole change set across files and `<leader>xq` renders it as a checklist in Trouble. `]h` / `[h` move between hunks inside the current file.

The default base is `HEAD`, not the index — gitsigns' own default hides anything you have already staged, which is precisely what you want to see when reviewing. Pass a ref to review against something else; branches and tags tab-complete:

```vim
:GitReview            " working tree vs HEAD (staged and unstaged)
:GitReview main       " everything on this branch, from the merge base with main
:GitReview HEAD~3
```

Naming a branch uses the **merge base**, so whatever landed on `main` after you branched stays out of the review.

`<leader>gr` again (or `:GitReviewOff`) turns the decorations off, puts the diff base back to the index, and wipes the buffers it opened — apart from any you edited or still have on screen. `<leader>gR` rebuilds the hunk list against the same base, for after staging or fixing part of what you are reviewing.

| Key | Action |
|---|---|
| `<leader>gr` | Start / end an inline diff review |
| `<leader>gR` | Rebuild the review's hunk list |
| `]h` / `[h` | Next / previous hunk in this file |
| `]q` / `[q` | Next / previous hunk in the review |
| `<leader>hp` | Preview the hunk in a float |
| `<leader>hs` / `<leader>hr` | Stage / reset the hunk |

For a side-by-side view instead, `:DiffviewOpen` is also installed.

## Keymaps

Leader: `<Space>`

### Telescope
| Key | Action |
|---|---|
| `<C-p>` / `<leader>ff` | Find files |
| `<leader>fg` | Live grep |
| `<leader>fw` | Grep the word under the cursor (or the visual selection) |
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

### Git (see [Reviewing changes](#reviewing-changes))
| Key | Action |
|---|---|
| `<leader>gg` | LazyGit |
| `<leader>gr` | Inline diff review of all changed files |
| `<leader>gR` | Rebuild the review's hunk list |
| `]h` / `[h` | Next / previous hunk |
| `<leader>hp` | Preview hunk |
| `<leader>hb` | Blame line |
| `<leader>hs` / `<leader>hS` | Stage hunk / buffer |
| `<leader>hr` / `<leader>hR` | Reset hunk / buffer |
| `<leader>hd` | Diff this file (side by side) |

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
