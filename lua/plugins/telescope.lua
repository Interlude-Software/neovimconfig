return {
    "nvim-telescope/telescope.nvim",
    tag = "0.1.8",
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
      -- Per-project excludes: a `.telescopeignore` file in the cwd, one
      -- glob per line (`#` comments and blank lines skipped). No nvim
      -- config changes needed to add project-specific excludes — just
      -- drop the file in the project root.
      local function extra_excludes()
          local path = vim.fn.getcwd() .. "/.telescopeignore"
          if vim.fn.filereadable(path) == 0 then
              return {}
          end
          local patterns = {}
          for _, line in ipairs(vim.fn.readfile(path)) do
              local trimmed = line:match("^%s*(.-)%s*$")
              if trimmed ~= "" and not trimmed:match("^#") then
                  table.insert(patterns, trimmed)
              end
          end
          return patterns
      end

      require("telescope").setup({
          defaults = {
              preview = { treesitter = false },
              file_ignore_patterns = {
                  "^node_modules/", "/node_modules/",
                  "^%.git/", "/%.git/",
                  "^build/", "/build/",
                  "^dist/", "/dist/",
                  "^Library/", "/Library/",
                  "^Temp/", "/Temp/",
                  "^obj/", "/obj/",
                  "^bin/", "/bin/",
                  "^Logs/", "/Logs/",
                  "^UserSettings/", "/UserSettings/",
                  "^CodeCoverage/", "/CodeCoverage/",
              },
          },
          pickers = {
              find_files = {
                  find_command = function()
                      local cmd = {
                          "fd", "--type", "f", "--hidden", "--no-ignore",
                          "--exclude", "Library",
                          "--exclude", "Temp",
                          "--exclude", "Logs",
                          "--exclude", "obj",
                          "--exclude", "bin",
                          "--exclude", ".git",
                          "--exclude", "UserSettings",
                          "--exclude", "CodeCoverage",
                      }
                      for _, pattern in ipairs(extra_excludes()) do
                          vim.list_extend(cmd, { "--exclude", pattern })
                      end
                      return cmd
                  end,
              },
              live_grep = {
                  additional_args = function()
                      local args = {
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
                      for _, pattern in ipairs(extra_excludes()) do
                          vim.list_extend(args, { "--glob", "!" .. pattern })
                      end
                      return args
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
