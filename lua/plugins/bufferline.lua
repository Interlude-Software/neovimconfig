return {
  'akinsho/bufferline.nvim',
  event = 'VeryLazy',
  dependencies = { 'nvim-tree/nvim-web-devicons' },
  config = function()
    vim.opt.termguicolors = true

    require('bufferline').setup({
      options = {
        mode = 'buffers',                 -- show open buffers (set 'tabs' to mirror :tabs instead)
        diagnostics = 'nvim_lsp',
        separator_style = 'slant',
        show_buffer_close_icons = true,
        show_close_icon = false,
        offsets = {
          { filetype = 'neo-tree', text = 'File Explorer', highlight = 'Directory', separator = true },
        },
      },
    })

    vim.keymap.set('n', '<Tab>', '<cmd>BufferLineCycleNext<cr>', { desc = 'Next buffer' })
    vim.keymap.set('n', '<S-Tab>', '<cmd>BufferLineCyclePrev<cr>', { desc = 'Prev buffer' })
    vim.keymap.set('n', '<leader>bp', '<cmd>BufferLineTogglePin<cr>', { desc = 'Pin buffer' })
    vim.keymap.set('n', '<leader>bd', '<cmd>bdelete<cr>', { desc = 'Delete buffer' })
  end,
}
