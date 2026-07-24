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
        vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts)
        vim.keymap.set('n', '<leader>gd', function() vim.cmd('vsplit'); vim.lsp.buf.definition() end, opts)
        vim.keymap.set('n', 'K',  vim.lsp.buf.hover, opts)
        vim.keymap.set('n', 'gr', vim.lsp.buf.references, opts)
        vim.keymap.set('n', '<leader>rn', function()
          vim.ui.input({ prompt = "New Name: ", default = "" }, function(new_name)
            if new_name and new_name ~= "" then
              vim.lsp.buf.rename(new_name)
            end
          end)
        end, opts)
        vim.keymap.set('n', '<leader>ca', vim.lsp.buf.code_action, opts)
      end,
    })
    vim.lsp.enable("roslyn")
  end,
}
