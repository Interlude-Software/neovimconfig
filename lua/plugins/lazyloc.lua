-- lazyloc — per-extension LOC counter.
-- https://github.com/Interlude-Software/lazyLOC
return {
  "Interlude-Software/lazyLOC",
  cmd = "LazyLoc",
  keys = {
    { "<leader>fL", "<cmd>LazyLoc<cr>", desc = "Line count (lazyloc)" },
  },
  opts = {},
}
