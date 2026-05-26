return {
  "CopilotC-Nvim/CopilotChat.nvim",
  dependencies = {
    "zbirenbaum/copilot.lua",
    "nvim-lua/plenary.nvim",
  },
  build = vim.fn.has("win32") == 1 and nil or "make tiktoken",
  opts = {
    window = {
      layout = "vertical",
      width = 0.35,
    },
  },
  keys = {
    { "<leader>cc", "<cmd>CopilotChatToggle<cr>",  desc = "Copilot Chat toggle" },
    { "<leader>ce", "<cmd>CopilotChatExplain<cr>", desc = "Copilot explain",    mode = { "n", "v" } },
    { "<leader>cf", "<cmd>CopilotChatFix<cr>",     desc = "Copilot fix",        mode = { "n", "v" } },
    { "<leader>cr", "<cmd>CopilotChatReview<cr>",  desc = "Copilot review",     mode = { "n", "v" } },
  },
}
