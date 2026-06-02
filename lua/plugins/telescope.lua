return {
    "nvim-telescope/telescope.nvim",
    tag = "0.1.8",
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
      local actions = require("telescope.actions")
      local action_state = require("telescope.actions.state")

      local function tab_drop(prompt_bufnr)
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        local path = entry.path or entry.filename
        if not path then return end
        for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
          for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
            local buf = vim.api.nvim_win_get_buf(win)
            if vim.api.nvim_buf_get_name(buf) == path then
              vim.api.nvim_set_current_tabpage(tab)
              vim.api.nvim_set_current_win(win)
              return
            end
          end
        end
        vim.cmd("tabnew " .. vim.fn.fnameescape(path))
      end

      require("telescope").setup({
          defaults = {
              preview = { treesitter = false },
              file_ignore_patterns = {
                  "node_modules",
                  "%.git",
                  "build",
                  "dist",
                  "Library",
                  "Temp",
                  "obj",
                  "bin",
                  "Logs",
                  "UserSettings",
                  "CodeCoverage",
              },
              mappings = {
                  i = { ["<CR>"] = tab_drop },
                  n = { ["<CR>"] = tab_drop },
              },
          },
          pickers = {
              find_files = {
                  find_command = {
                      "fd", "--type", "f", "--hidden", "--no-ignore",
                      "--exclude", "Library",
                      "--exclude", "Temp",
                      "--exclude", "Logs",
                      "--exclude", "obj",
                      "--exclude", "bin",
                      "--exclude", ".git",
                      "--exclude", "UserSettings",
                      "--exclude", "CodeCoverage",
                  },
              },
              live_grep = {
                  additional_args = function()
                      return {
                          "--no-ignore",
                          "--glob", "!Library/",
                          "--glob", "!Temp/",
                          "--glob", "!Logs/",
                          "--glob", "!obj/",
                          "--glob", "!bin/",
                          "--glob", "!.git/",
                          "--glob", "!UserSettings/",
                          "--glob", "!CodeCoverage/",
                      }
                  end,
              },
          },
      })

      local builtin = require("telescope.builtin")
      vim.keymap.set("n", "<C-p>", builtin.find_files, { desc = "Find files" })
      vim.keymap.set("n", "<leader>ff", builtin.find_files, { desc = "Find files" })
      vim.keymap.set("n", "<leader>fg", builtin.live_grep,  { desc = "Live grep" })
      vim.keymap.set("n", "<leader>fb", builtin.buffers,    { desc = "Buffers" })
      vim.keymap.set("n", "<leader>fh", builtin.help_tags,  { desc = "Help tags" })
      vim.keymap.set("n", "<leader>fc", function()
        builtin.live_grep({
          glob_pattern = "*.cs",
          prompt_title = "Live Grep (C#)",
        })
      end, { desc = "Live grep C#" })
    end,
  }
