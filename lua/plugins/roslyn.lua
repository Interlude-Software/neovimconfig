return {
  "seblj/roslyn.nvim",
  ft = "cs",
  cmd = { "Roslyn" },
  opts = {
    extensions = {
      razor = { enabled = false },
    },
  },
  init = function()
    vim.lsp.config("roslyn", {
      capabilities = require('cmp_nvim_lsp').default_capabilities(),
      on_attach = function(_, bufnr)
        local opts = { buffer = bufnr }
        vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts)
        vim.keymap.set('n', 'K',  vim.lsp.buf.hover, opts)
        vim.keymap.set('n', 'gr', vim.lsp.buf.references, opts)
        vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, opts)
        vim.keymap.set('n', '<leader>ca', vim.lsp.buf.code_action, opts)
      end,
    })
    vim.lsp.enable("roslyn")
  end,
}
