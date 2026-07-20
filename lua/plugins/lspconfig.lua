return {
  "neovim/nvim-lspconfig",
  ft = { "c", "cpp", "objc", "objcpp", "cuda", "lua" },
  init = function()
    local function on_attach(_, bufnr)
      local opts = { buffer = bufnr }
      vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts)
      vim.keymap.set('n', '<leader>gd', function() vim.cmd('vsplit'); vim.lsp.buf.definition() end, opts)
      vim.keymap.set('n', 'K',  vim.lsp.buf.hover, opts)
      vim.keymap.set('n', 'gr', vim.lsp.buf.references, opts)
      vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, opts)
      vim.keymap.set('n', '<leader>ca', vim.lsp.buf.code_action, opts)
    end

    vim.lsp.config("clangd", {
      capabilities = require('cmp_nvim_lsp').default_capabilities(),
      on_attach = function(client, bufnr)
        on_attach(client, bufnr)
        vim.keymap.set('n', 'gh', function()
          vim.lsp.buf_request(bufnr, 'textDocument/switchSourceHeader', vim.lsp.util.make_text_document_params(), function(err, result)
            if err then
              vim.notify('switchSourceHeader failed: ' .. err.message, vim.log.levels.ERROR)
              return
            end
            if not result then
              vim.notify('No corresponding header/source file found', vim.log.levels.WARN)
              return
            end
            vim.cmd.edit(vim.uri_to_fname(result))
          end)
        end, { buffer = bufnr })
      end,
    })
    vim.lsp.enable("clangd")

    -- lazydev.nvim supplies the `vim` global and lazy.nvim plugin-spec types,
    -- so no manual settings.Lua.diagnostics/workspace hacks needed here.
    vim.lsp.config("lua_ls", {
      capabilities = require('cmp_nvim_lsp').default_capabilities(),
      on_attach = on_attach,
    })
    vim.lsp.enable("lua_ls")
  end,
}
