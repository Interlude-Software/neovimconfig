return {
  "stevearc/conform.nvim",
  event = "BufWritePre",
  opts = {
    format_on_save = {
      timeout_ms = 3000,
      lsp_format = "fallback",
    },
    formatters_by_ft = {
      lua = { "stylua" },
      cs  = { "csharpier" },
    },
  },
}
