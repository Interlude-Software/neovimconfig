# Neovim Config

Uses [lazy.nvim](https://github.com/folke/lazy.nvim). Plugins install on first launch. External tools must be on `PATH`.

## Requirements

| Tool | Purpose |
|---|---|
| Neovim 0.10+ | |
| Git | lazy.nvim bootstrap |
| [fd](https://github.com/sharkdp/fd) | Telescope `find_files` |
| [ripgrep](https://github.com/BurntSushi/ripgrep) | Telescope `live_grep` |
| [lazygit](https://github.com/jesseduffield/lazygit) | `<leader>gg` |
| [.NET SDK 8+](https://dotnet.microsoft.com/download) | Roslyn LSP |

## Install

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
2. `:MasonInstall roslyn`
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

### LSP (`.cs`)
| Key | Action |
|---|---|
| `gd` | Go to definition |
| `K` | Hover |
| `gr` | References |
| `<leader>rn` | Rename |
| `<leader>ca` | Code actions |

### Git
| Key | Action |
|---|---|
| `<leader>gg` | LazyGit |

### Debug (`.cs`)
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
