return {
  "OXY2DEV/markview.nvim",
  lazy = false, -- recommended; markview manages its own lazy-loading by filetype
  dependencies = {
    "nvim-treesitter/nvim-treesitter", -- needs markdown + markdown_inline parsers
    "nvim-tree/nvim-web-devicons", -- icons in rendered output
  },
  keys = {
    { "<leader>m", "<cmd>Markview Toggle<cr>", desc = "Markview: toggle rendering" },
  },
}
