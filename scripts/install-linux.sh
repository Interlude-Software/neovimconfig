#!/usr/bin/env bash
#
# Installs every external tool this Neovim config needs, on Linux x86_64.
# All binaries go into ~/.local/bin (no sudo). Re-runnable / idempotent.
#
# After this, the only in-editor step left is the Mason tools, which this
# script also triggers headlessly at the end (roslyn + netcoredbg).
#
set -euo pipefail

BIN="$HOME/.local/bin"
mkdir -p "$BIN"

arch="$(uname -m)"
if [[ "$arch" != "x86_64" ]]; then
  echo "This script only handles x86_64 (got: $arch). Install the tools manually." >&2
  exit 1
fi

# Latest release tag for a GitHub repo, e.g. "10.4.2" (leading "v" stripped).
latest() { curl -fsSL "https://api.github.com/repos/$1/releases/latest" | grep -oP '"tag_name":\s*"v?\K[^"]+'; }

note() { printf '\n==> %s\n' "$*"; }

# --- fd : Telescope find_files (config hardcodes the name `fd`) -------------
note "fd"
v="$(latest sharkdp/fd)"
curl -fsSL "https://github.com/sharkdp/fd/releases/download/v${v}/fd-v${v}-x86_64-unknown-linux-gnu.tar.gz" | tar xz -C /tmp
install -m755 "/tmp/fd-v${v}-x86_64-unknown-linux-gnu/fd" "$BIN/fd"
rm -rf "/tmp/fd-v${v}-x86_64-unknown-linux-gnu"

# --- ripgrep : Telescope live_grep -----------------------------------------
# NB: must be a REAL binary on PATH. A shell alias/function for `rg` (e.g. the
# one Claude Code injects) is invisible to Telescope, which spawns rg directly.
note "ripgrep"
v="$(latest BurntSushi/ripgrep)"
curl -fsSL "https://github.com/BurntSushi/ripgrep/releases/download/${v}/ripgrep-${v}-x86_64-unknown-linux-musl.tar.gz" | tar xz -C /tmp
install -m755 "/tmp/ripgrep-${v}-x86_64-unknown-linux-musl/rg" "$BIN/rg"
rm -rf "/tmp/ripgrep-${v}-x86_64-unknown-linux-musl"

# --- lazygit : <leader>gg --------------------------------------------------
note "lazygit"
v="$(latest jesseduffield/lazygit)"
curl -fsSL "https://github.com/jesseduffield/lazygit/releases/download/v${v}/lazygit_${v}_Linux_x86_64.tar.gz" | tar xz -C /tmp lazygit
install -m755 /tmp/lazygit "$BIN/lazygit"
rm -f /tmp/lazygit

# --- tree-sitter CLI : nvim-treesitter compiles parsers with it ------------
note "tree-sitter CLI"
v="$(latest tree-sitter/tree-sitter)"
curl -fsSL "https://github.com/tree-sitter/tree-sitter/releases/download/v${v}/tree-sitter-linux-x64.gz" | gunzip > "$BIN/tree-sitter"
chmod 755 "$BIN/tree-sitter"

# --- stylua : conform format-on-save (Lua) ---------------------------------
note "stylua"
v="$(latest JohnnyMorganz/StyLua)"
curl -fsSL -o /tmp/stylua.zip "https://github.com/JohnnyMorganz/StyLua/releases/download/v${v}/stylua-linux-x86_64.zip"
unzip -oq /tmp/stylua.zip stylua -d /tmp
install -m755 /tmp/stylua "$BIN/stylua"
rm -f /tmp/stylua.zip /tmp/stylua

# --- csharpier : conform format-on-save (C#) — dotnet global tool ----------
if command -v dotnet >/dev/null 2>&1; then
  note "csharpier (dotnet tool)"
  dotnet tool install -g csharpier 2>/dev/null || dotnet tool update -g csharpier
else
  echo "!! dotnet not found — skipping csharpier (C# formatting). Install the .NET SDK 8+ and re-run." >&2
fi

# --- lazygit config symlink (this repo is the source of truth) -------------
note "lazygit config symlink"
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$HOME/.config/lazygit"
ln -sf "$repo_dir/lazygit/config.yml" "$HOME/.config/lazygit/config.yml"

# --- Mason tools (need nvim): roslyn LSP + netcoredbg debugger --------------
if command -v nvim >/dev/null 2>&1; then
  note "Mason: roslyn + netcoredbg (headless, may take a minute)"
  nvim --headless -c "MasonInstall roslyn netcoredbg" -c "qa" || \
    echo "!! Mason install had issues — open nvim and run :MasonInstall roslyn netcoredbg manually." >&2
else
  echo "!! nvim not found — install Neovim 0.10+, then run :MasonInstall roslyn netcoredbg." >&2
fi

# --- PATH sanity check -----------------------------------------------------
note "Done."
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "!! $BIN is not on your PATH. Add this to your shell rc:"; echo '   export PATH="$HOME/.local/bin:$PATH"' ;;
esac
if command -v dotnet >/dev/null 2>&1; then
  case ":$PATH:" in
    *":$HOME/.dotnet/tools:"*) ;;
    *) echo "!! ~/.dotnet/tools is not on your PATH (needed for csharpier). Add:"; echo '   export PATH="$HOME/.dotnet/tools:$PATH"' ;;
  esac
fi
echo "Installed into $BIN: fd, rg, lazygit, tree-sitter, stylua"
