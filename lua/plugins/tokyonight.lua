 return {
  'folke/tokyonight.nvim',
  lazy = false,
  priority = 1000,
  config = function()
    vim.cmd.colorscheme('tokyonight-night')
    -- variants: tokyonight-night, tokyonight-storm, tokyonight-day, tokyonight-moon
  end,
}
