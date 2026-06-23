return {
  'ayu-theme/ayu-vim',
  lazy = false,
  priority = 1000,
  config = function()
    vim.g.ayucolor = 'dark' -- 'light', 'mirage' or 'dark'
    vim.cmd.colorscheme('ayu')
  end,
}
