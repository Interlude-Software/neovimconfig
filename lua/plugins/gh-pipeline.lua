-- Local, in-development plugin (will become its own open-source repo).
-- Lives in ~/.config/nvim/gh-pipeline; loaded by lazy as a `dir` plugin.
return {
  dir = vim.fn.stdpath("config") .. "/gh-pipeline",
  name = "gh-pipeline",
  lazy = true,
  cmd = { "GhPipeline", "GhPipelineQueue" },
  keys = {
    { "<leader>gp", "<cmd>GhPipeline<cr>", desc = "GitHub Actions (queued/running)" },
    { "<leader>gq", "<cmd>GhPipelineQueue<cr>", desc = "GitHub CI queue (processing order)" },
  },
  config = function()
    require("gh-pipeline").setup()
  end,
}
