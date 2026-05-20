return {
  "folke/which-key.nvim",
  event = "VeryLazy",
  opts = {
    delay = 500,
    spec = {
      { "<leader>d", group = "debug" },
      { "<leader>x", group = "trouble" },
      { "<leader>r", group = "rename/refactor" },
      { "<leader>c", group = "code action" },
    },
  },
}
