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
      cs = { "csharpier" },
      c = { "clang-format" },
      cpp = { "clang-format" },
      objc = { "clang-format" },
      objcpp = { "clang-format" },
      cuda = { "clang-format" },
    },
    formatters = {
      ["clang-format"] = {
        prepend_args = { "--style=file", "--fallback-style=Microsoft" },
      },
    },
  },
}
