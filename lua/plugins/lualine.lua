return {
  "nvim-lualine/lualine.nvim",
  event = "VeryLazy",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  config = function()
    require("lualine").setup({
      options = {
        theme = "onedark",
        icons_enabled = true,
        globalstatus = true, -- single statusline across all splits
        section_separators = { left = "", right = "" },
        component_separators = { left = "", right = "" },
      },
      sections = {
        lualine_a = { "mode" },
        lualine_b = { "branch", "diff", "diagnostics" },
        lualine_c = {
          { "filename", path = 1 }, -- relative path
          {
            function()
              return require("user.build").statusline()
            end,
            color = function()
              return require("user.build").statusline_hl()
            end,
          },
          {
            function()
              return require("user.run").statusline()
            end,
            color = function()
              return require("user.run").statusline_hl()
            end,
          },
        },
        lualine_x = { "encoding", "fileformat", "filetype" },
        lualine_y = { "progress" },
        lualine_z = { "location" },
      },
    })
  end,
}
