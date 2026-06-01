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
          vim.cmd("tab drop " .. vim.fn.fnameescape(item.filename))
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
