#!/bin/bash
# Forward Unity's file/line into the running nvim via the shared wrapper.
exec "$HOME/.local/bin/nvim-unity" "$@"
