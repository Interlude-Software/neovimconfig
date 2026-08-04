return {
  "sindrets/diffview.nvim",
  cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewToggleFiles", "DiffviewFocusFiles", "DiffviewFileHistory" },
  dependencies = { "nvim-tree/nvim-web-devicons" },
  config = function()
    require("diffview").setup({})
  end,
}
