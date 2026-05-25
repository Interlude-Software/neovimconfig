return {
    "nvim-telescope/telescope.nvim",
    tag = "0.1.8",
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
      require("telescope").setup({
          defaults = {
              preview = { treesitter = false },
              file_ignore_patterns = {
                  "node_modules",
                  "%.git",
                  "build",
                  "dist",
                  "Library",     -- Unity
                  "Temp",        -- Unity
                  "obj",         -- C#/.NET
                  "bin",
                  "Logs",
                  "UserSettings",
                  "CodeCoverage",
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
      vim.keymap.set("n", "<C-p>", builtin.find_files, {desc = "Find files" })
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
