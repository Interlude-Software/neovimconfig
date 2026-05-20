-- Set the leader key BEFORE lazy loads (needed for keymaps below)
vim.g.mapleader = " "

-- Ensure Git's diff is available on Windows
vim.env.PATH = vim.env.PATH .. ";C:\\Program Files\\Git\\usr\\bin"

-- Bootstrap lazy.nvim (downloads it the first time you run nvim)
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git", "clone", "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", lazypath,
  })
end

vim.opt.rtp:prepend(lazypath)

vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.cursorline = true      -- highlight the current line
vim.opt.signcolumn = 'yes'     -- always show sign column (prevents text shifting when gitsigns/LSP add signs)
vim.opt.scrolloff = 8          -- keep 8 lines visible above/below cursor
vim.opt.expandtab = true       -- tabs become spaces
vim.opt.tabstop = 4            -- tab width
vim.opt.shiftwidth = 4         -- indent width
vim.opt.smartindent = true     -- auto-indent new lines
vim.opt.wrap = false           -- don't wrap long lines
vim.opt.ignorecase = true      -- case-insensitive search...
vim.opt.smartcase = true       -- ...unless you use a capital letter
vim.opt.termguicolors = true   -- enable 24-bit colors (themes need this)

require("lazy").setup("plugins")
