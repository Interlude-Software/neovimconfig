# Neovim Config Setup

This config uses [lazy.nvim](https://github.com/folke/lazy.nvim), which bootstraps itself on first launch. The Neovim plugins install automatically — but several **external tools** must be on your `PATH` first.

---

## Requirements

| Tool | Used by | Min version |
|---|---|---|
| Neovim | — | 0.10+ |
| Git | lazy.nvim bootstrap | any |
| [fd](https://github.com/sharkdp/fd) | Telescope `find_files` | any |
| [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) | Telescope `live_grep` | any |
| [lazygit](https://github.com/jesseduffield/lazygit) | `<leader>gg` LazyGit UI | any |
| [.NET SDK](https://dotnet.microsoft.com/download) | Roslyn LSP server | 8.0+ |

---

## macOS

Install everything via Homebrew:

```sh
brew install neovim fd ripgrep lazygit dotnet
```

Verify they're all on your PATH:

```sh
nvim --version
fd --version
rg --version
lazygit --version
dotnet --version
```

---

## Windows

Install via winget:

```powershell
winget install Neovim.Neovim
winget install sharkdp.fd
winget install BurntSushi.ripgrep.MSVC
winget install JesseDuffield.lazygit
winget install Microsoft.DotNet.SDK.8
```

Also install Git for Windows if you don't already have it (the config adds `C:\Program Files\Git\usr\bin` to `PATH` automatically at startup):

```powershell
winget install Git.Git
```

After installing, open a **new** terminal so the updated PATH takes effect, then verify each tool with `--version`.

---

## Unity Debugging Setup

Unity uses the Mono runtime, so `netcoredbg` won't work. This config uses the **UnityDebugAdapter** that ships inside the [Visual Studio Tools for Unity](https://marketplace.visualstudio.com/items?itemName=visualstudiotoolsforunity.vstuc) VS Code extension (`vstuc`). The adapter is a .NET 10 DLL invoked via `dotnet` — no separate binary install is needed.

### Prerequisites

- **VS Code** with the **Visual Studio Tools for Unity** extension (`visualstudiotoolsforunity.vstuc`) installed.
- **.NET SDK 10.0+** (already listed in Requirements above).

The config automatically finds the adapter using a glob on `~/.vscode/extensions/visualstudiotoolsforunity.vstuc-*/bin/UnityDebugAdapter.dll`, so it keeps working after extension updates.

### Plugin install

`lua/plugins/dap.lua` is already in this config. On first launch after pulling this config, lazy.nvim will install `nvim-dap`, `nvim-dap-ui`, and `nvim-nio` automatically.

### Unity Editor settings

No special Unity project settings are needed for in-Editor debugging. Unity opens a Mono debug port automatically when the Editor is running.

To debug standalone builds: enable **Development Build** and **Script Debugging** in **File → Build Settings** before building.

### Attach workflow

1. Open your Unity project in the Unity Editor.
2. Open a `.cs` file in Neovim and set a breakpoint with `<leader>db`.
3. Press `<F5>` to attach. The adapter will discover running Unity instances — select the Editor from the prompt.
4. Hit Play in Unity. Execution will pause at your breakpoint.

---

## First Launch

1. Open Neovim: `nvim`
2. lazy.nvim will download and install all plugins automatically. Wait for it to finish.
3. Install the Roslyn LSP server via Mason:
   ```
   :MasonInstall roslyn
   ```
   Mason pulls Roslyn from the [Crashdummyy mason-registry](https://github.com/Crashdummyy/mason-registry), which is already registered in the config.
4. Restart Neovim. Open any `.cs` file — Roslyn will start up and attach.

---

## Keymaps

**Leader key: `<Space>`**

### Telescope
| Key | Action |
|---|---|
| `<C-p>` or `<leader>ff` | Find files (`fd`) |
| `<leader>fg` | Live grep (`rg`) |
| `<leader>fb` | Open buffers |
| `<leader>fh` | Help tags |
| `<leader>fc` | Live grep C# files only |

### LSP (active on `.cs` files)
| Key | Action |
|---|---|
| `gd` | Go to definition |
| `K` | Hover docs |
| `gr` | Find references |
| `<leader>rn` | Rename symbol |
| `<leader>ca` | Code actions |

### Git
| Key | Action |
|---|---|
| `<leader>gg` | Open LazyGit |

### Debugging (active on `.cs` files)
| Key | Action |
|---|---|
| `<leader>db` | Toggle breakpoint |
| `<F5>` or `<leader>dc` | Continue / attach |
| `<F10>` | Step over |
| `<F11>` | Step into |
| `<F12>` | Step out |
| `<leader>du` | Toggle debug UI |

### Misc
| Key | Action |
|---|---|
| `<leader>u` | Toggle Undotree |
