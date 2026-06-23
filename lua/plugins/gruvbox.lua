return {
  'ellisonleao/gruvbox.nvim',
  lazy = false,
  priority = 1000,
  config = function()
    require('gruvbox').setup({
      contrast = 'hard', -- "hard", "soft" or "" (medium)
    })
    vim.o.background = 'dark' -- or 'light'
    -- vim.cmd.colorscheme('gruvbox') -- ayu is the active theme (see ayu.lua)
  end,
}
