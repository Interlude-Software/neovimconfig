return {
  "navarasu/onedark.nvim",
  lazy = false,
  priority = 1000, -- load before anything that reads highlight groups
  config = function()
    require("onedark").setup({
      -- dark | darker | cool | deep | warm | warmer | light
      style = "deep",
    })
    -- load() rather than :colorscheme, which would bypass the style above
    require("onedark").load()
  end,
}
