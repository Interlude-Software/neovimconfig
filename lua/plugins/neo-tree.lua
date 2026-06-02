return {
  "nvim-neo-tree/neo-tree.nvim",
  branch = "v3.x",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-tree/nvim-web-devicons",
    "MunifTanjim/nui.nvim",
  },
  keys = {
    { "<leader>e", "<cmd>Neotree toggle<cr>", desc = "Toggle file tree" },
    { "<leader>o", "<cmd>Neotree reveal<cr>", desc = "Reveal file in tree" },
  },
  opts = {
    filesystem = {
      filtered_items = {
        hide_dotfiles = false,
        hide_gitignored = true,
        hide_by_name = {
          "Library",
          "Temp",
          "Logs",
          "obj",
          "bin",
          "UserSettings",
          "CodeCoverage",
        },
      },
      follow_current_file = { enabled = true },
    },
    window = {
      position = "left",
      width = 35,
    },
  },
}
