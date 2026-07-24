-- Set the leader key BEFORE lazy loads (needed for keymaps below)
vim.g.mapleader = " "

-- Listen on a fixed socket so external tools (Unity) can open files here.
-- Only the first nvim binds it; later instances skip it silently. If a
-- previous nvim crashed and left a stale socket, reclaim it.
local server_sock = vim.fn.expand("~/.cache/nvim/server.pipe")
if not pcall(vim.fn.serverstart, server_sock) then
  -- "address already in use" — check whether a live nvim actually owns it.
  local ok, chan = pcall(vim.fn.sockconnect, "pipe", server_sock, { rpc = true })
  if ok and chan ~= 0 then
    vim.fn.chanclose(chan) -- a live server is there; leave it alone
  else
    vim.fn.delete(server_sock) -- stale socket from a crashed nvim; rebind
    pcall(vim.fn.serverstart, server_sock)
  end
end

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
vim.opt.colorcolumn = "120"    -- show print width guide
vim.opt.ignorecase = true      -- case-insensitive search...
vim.opt.smartcase = true       -- ...unless you use a capital letter
vim.opt.termguicolors = true   -- enable 24-bit colors (themes need this)
vim.opt.splitright = true      -- vertical splits open to the right
vim.opt.splitbelow = true      -- horizontal splits open below
vim.opt.shortmess:append("A")  -- skip the swap-file ATTENTION prompt (crashes LSP jump handlers otherwise)

require("lazy").setup("plugins")

vim.keymap.set('n', ']w', function() vim.diagnostic.goto_next({ severity = vim.diagnostic.severity.WARN }) end)
vim.keymap.set('n', '[w', function() vim.diagnostic.goto_prev({ severity = vim.diagnostic.severity.WARN }) end)
vim.keymap.set('n', ']e', function() vim.diagnostic.goto_next({ severity = vim.diagnostic.severity.ERROR }) end)
vim.keymap.set('n', '[e', function() vim.diagnostic.goto_prev({ severity = vim.diagnostic.severity.ERROR }) end)
