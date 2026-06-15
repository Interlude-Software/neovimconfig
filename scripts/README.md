# Unity → nvim "open in running editor" scripts

These let double-clicking a C# script in Unity open it in your **already-running**
terminal nvim (the one that started the server socket in `init.lua`).

These files live outside this repo when installed; the copies here are the
source of truth. To (re)install:

```sh
# 1. The forwarder Unity ultimately calls
cp scripts/nvim-unity ~/.local/bin/nvim-unity
chmod +x ~/.local/bin/nvim-unity

# 2. The .app Unity selects as its External Script Editor (macOS only lets you
#    pick .app bundles, so this stub just execs the forwarder above)
cp scripts/NvimUnity.app-launcher.sh /Applications/NvimUnity.app/Contents/MacOS/nvimunity
chmod +x /Applications/NvimUnity.app/Contents/MacOS/nvimunity
```

## Unity-side config (not in any file — set in the Unity GUI)

Settings → External Tools:
- **External Script Editor** = NvimUnity (`/Applications/NvimUnity.app`)
- **External Script Editor Args** = `"$(File)" $(Line)`

## How it works

- `init.lua` runs `serverstart(~/.cache/nvim/server.pipe)` so the first nvim
  instance listens on a fixed socket.
- `nvim-unity` forwards the file+line to that socket via `--remote-silent` then
  `--remote-send :<line>`; falls back to launching a fresh nvim if no server.
- Only the first nvim binds the socket, so Unity always opens into whichever
  nvim started first. Switch focus to that terminal yourself — Unity can't.
