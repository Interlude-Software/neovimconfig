-- lazyissues — lazygit-style TUI for the repo's file-based issue tracker.
-- https://github.com/Interlude-Software/lazyissues
return {
  "Interlude-Software/lazyissues",
  cmd = "LazyIssues",
  dependencies = { "MunifTanjim/nui.nvim" },
  keys = {
    { "<leader>i", "<cmd>LazyIssues<cr>", desc = "Issues (lazyissues)" },
  },
  opts = {},
}
