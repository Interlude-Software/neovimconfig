-- lazyloc — local, in-development plugin at ~/Desktop/lazyloc, not yet pushed
-- to a git remote. Loaded by lazy as a `dir` plugin until it is.
return {
  dir = vim.fn.expand("~/Desktop/lazyloc"),
  name = "lazyloc",
  lazy = true,
  cmd = "LazyLoc",
  keys = {
    { "<leader>fL", "<cmd>LazyLoc<cr>", desc = "Line count (lazyloc)" },
  },
  opts = {},
}
