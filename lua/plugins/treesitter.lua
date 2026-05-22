return {
  "nvim-treesitter/nvim-treesitter",
  build = ":TSUpdate",
  config = function()
    -- New nvim-treesitter (v1.x): no configs.setup() — highlighting is automatic via ftplugins.
    require("nvim-treesitter.install").install({
      "c_sharp", "lua", "vim", "vimdoc", "json", "yaml", "markdown",
    })

    -- telescope.nvim still calls parsers.ft_to_lang which was removed
    local ok, parsers = pcall(require, "nvim-treesitter.parsers")
    if ok and not parsers.ft_to_lang then
      parsers.ft_to_lang = function(ft)
        return vim.treesitter.language.get_lang(ft) or ft
      end
    end
  end,
}
