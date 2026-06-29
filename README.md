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

LSP (`clangd`) and debugging (`codelldb`) install via Mason on first launch. clangd resolves include paths from a `compile_commands.json`, `compile_flags.txt`, or `.clangd` in the project root — without one you'll see false errors on system headers. Generate it with CMake (`-DCMAKE_EXPORT_COMPILE_COMMANDS=ON`) or `bear -- make`.

Debug: open a `.c`/`.cpp` file, set a breakpoint (`<leader>db`), press `<F5>`. The C/C++ launch ("Launch C/C++ executable") and attach configs are listed first when the current buffer is native code.

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

### Misc
| Key | Action |
|---|---|
| `<leader>u` | Undotree |
