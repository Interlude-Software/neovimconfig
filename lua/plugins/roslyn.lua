return {
  "seblj/roslyn.nvim",
  ft = "cs",
  cmd = { "Roslyn" },
  opts = {},
  init = function()
    local exe
    if vim.fn.has("win32") == 1 then
      exe = vim.fn.expand("$LOCALAPPDATA/roslyn-ls/content/LanguageServer/win-x64/Microsoft.CodeAnalysis.LanguageServer.exe")
    else
      exe = vim.fn.expand("~/.local/share/roslyn-ls/Microsoft.CodeAnalysis.LanguageServer")
    end

    vim.lsp.config("roslyn", {
      cmd = {
        exe,
        "--logLevel=Information",
        "--extensionLogDirectory=" .. vim.fn.stdpath("data"),
        "--stdio",
      },
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
  end,
}
