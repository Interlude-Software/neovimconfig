return {
  "seblj/roslyn.nvim",
  ft = "cs",
  cmd = { "Roslyn" },
  opts = {
    broad_search = true,
  },
  init = function()
    vim.lsp.config("roslyn", {
      capabilities = require('cmp_nvim_lsp').default_capabilities(),
      on_attach = function(_, bufnr)
        local opts = { buffer = bufnr }
        local function tab_drop_list(o)
          local item = o.items[1]
          if not item then return end
          local path = vim.fn.fnamemodify(item.filename, ":p")
          for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
            for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
              local buf = vim.api.nvim_win_get_buf(win)
              if vim.api.nvim_buf_get_name(buf) == path then
                vim.api.nvim_set_current_tabpage(tab)
                vim.api.nvim_set_current_win(win)
                vim.api.nvim_win_set_cursor(0, { item.lnum, item.col - 1 })
                return
              end
            end
          end
          vim.cmd("tabnew " .. vim.fn.fnameescape(path))
          vim.api.nvim_win_set_cursor(0, { item.lnum, item.col - 1 })
        end
        vim.keymap.set('n', 'gd', function() vim.lsp.buf.definition({ on_list = tab_drop_list }) end, opts)
        vim.keymap.set('n', 'K',  vim.lsp.buf.hover, opts)
        vim.keymap.set('n', 'gr', vim.lsp.buf.references, opts)
        vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, opts)
        vim.keymap.set('n', '<leader>ca', vim.lsp.buf.code_action, opts)
      end,
    })
    vim.lsp.enable("roslyn")
  end,
}
