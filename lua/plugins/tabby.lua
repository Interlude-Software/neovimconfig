return {
  'nanozuki/tabby.nvim',
  event = 'VeryLazy',
  dependencies = { 'nvim-tree/nvim-web-devicons' },
  config = function()
    vim.opt.showtabline = 2

    local palette = {
      { bg = '#7aa2f7', fg = '#1a1b26' },
      { bg = '#9ece6a', fg = '#1a1b26' },
      { bg = '#e0af68', fg = '#1a1b26' },
      { bg = '#f7768e', fg = '#1a1b26' },
      { bg = '#bb9af7', fg = '#1a1b26' },
      { bg = '#7dcfff', fg = '#1a1b26' },
      { bg = '#ff9e64', fg = '#1a1b26' },
    }

    local function apply_hls()
      for i, c in ipairs(palette) do
        vim.api.nvim_set_hl(0, 'TabbyTab' .. i, { bg = c.bg, fg = c.fg })
        vim.api.nvim_set_hl(0, 'TabbyTabSel' .. i, { bg = c.bg, fg = c.fg, bold = true, underline = true })
      end
    end
    apply_hls()
    vim.api.nvim_create_autocmd('ColorScheme', { callback = apply_hls })

    require('tabby').setup({
      line = function(line)
        return {
          {
            { '  ', hl = 'TabLine' },
          },
          line.tabs().foreach(function(tab)
            local tabnr = vim.api.nvim_tabpage_get_number(tab.id)
            local idx = ((tabnr - 1) % #palette) + 1
            local hl = tab.is_current() and ('TabbyTabSel' .. idx) or ('TabbyTab' .. idx)
            return {
              ' ',
              tab.number(),
              ': ',
              tab.name(),
              tab.close_btn('×'),
              ' ',
              hl = hl,
              margin = ' ',
            }
          end),
          line.spacer(),
          hl = 'TabLineFill',
        }
      end,
    })

    vim.keymap.set('n', '<leader>tn', '<cmd>tabnew<cr>', { desc = 'New tab' })
    vim.keymap.set('n', '<leader>tc', '<cmd>tabclose<cr>', { desc = 'Close tab' })
    vim.keymap.set('n', '<leader>to', '<cmd>tabonly<cr>', { desc = 'Close other tabs' })
    vim.keymap.set('n', '<leader>tr', function()
      vim.ui.input({ prompt = 'Rename tab: ' }, function(name)
        if name and name ~= '' then require('tabby').tab_rename(name) end
      end)
    end, { desc = 'Rename tab' })
  end,
}
