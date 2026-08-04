return {
  "mbbill/undotree",
  keys = {
    { "<leader>u", "<cmd>UndotreeToggle<cr>", mode = "n", desc = "Toggle Undotree" },
  },
  config = function()
    vim.g.undotree_WindowLayout = 2 -- tree on left, diff below
    vim.g.undotree_SetFocusWhenToggle = 1 -- focus the tree when opened
  end,
}
