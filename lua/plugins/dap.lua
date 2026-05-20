return {
  "mfussenegger/nvim-dap",
  dependencies = {
    "rcarriga/nvim-dap-ui",
    "nvim-neotest/nvim-nio",
  },
  config = function()
    local dap = require("dap")
    local dapui = require("dapui")

    dapui.setup()

    dap.listeners.after.event_initialized["dapui_config"] = dapui.open
    dap.listeners.before.event_terminated["dapui_config"] = dapui.close
    dap.listeners.before.event_exited["dapui_config"] = dapui.close

    local adapter_dll = vim.fn.glob(
      vim.fn.expand("~/.vscode/extensions/visualstudiotoolsforunity.vstuc-*/bin/UnityDebugAdapter.dll")
    )

    dap.adapters.vstuc = {
      type = "executable",
      command = "dotnet",
      args = { adapter_dll },
    }

    local function unity_project_path(pid)
      local args = vim.fn.trim(vim.fn.system("ps -p " .. pid .. " -o args="))
      local s, e = args:lower():find("%-projectpath%s+")
      if not s then return nil end
      local rest = args:sub(e + 1)
      return rest:match("(.-)%s+%-%a") or rest:match("(.+)$")
    end

    local unity_selection = nil

    local function discover_unity()
      local raw = vim.fn.systemlist(
        "lsof -i TCP -n -P 2>/dev/null | grep LISTEN | grep -i unity | grep '127.0.0.1:56'"
          .. " | awk '{print $1, $2, $(NF-1)}'"
      )
      local entries = {}
      local pid_project = {}
      for _, line in ipairs(raw) do
        local proc, pid, addr = line:match("(%S+)%s+(%d+)%s+(%S+)")
        if addr and addr:match("^127%.0%.0%.1:%d+$") then
          if not pid_project[pid] then
            pid_project[pid] = unity_project_path(pid) or ""
          end
          local project = pid_project[pid]
          local name = vim.fn.fnamemodify(project, ":t")
          table.insert(entries, {
            pid     = pid,
            addr    = addr,
            project = project,
            label   = (name ~= "" and name or proc) .. " (PID " .. pid .. ")  " .. addr
                        .. (project ~= "" and ("  [" .. project .. "]") or ""),
          })
        end
      end
      return entries
    end

    dap.configurations.cs = {
      {
        type = "vstuc",
        request = "attach",
        name = "Attach to Unity Editor",
        endPoint = function()
          local entries = discover_unity()
          if #entries == 0 then
            vim.notify("No Unity debug ports found — is the Editor running?", vim.log.levels.ERROR)
            return nil
          end
          local entry
          if #entries == 1 then
            entry = entries[1]
          else
            local labels = { "Select Unity instance:" }
            for i, e in ipairs(entries) do
              table.insert(labels, i .. ". " .. e.label)
            end
            local choice = vim.fn.inputlist(labels)
            if choice < 1 or choice > #entries then return nil end
            entry = entries[choice]
          end
          unity_selection = entry
          return entry.addr
        end,
        projectPath = function()
          if unity_selection then
            return unity_selection.project
          end
          local pids = vim.fn.systemlist("pgrep -x Unity 2>/dev/null")
          if #pids == 1 then
            local path = unity_project_path(vim.fn.trim(pids[1]))
            if path then return path end
          end
          return vim.fn.input("Unity project path: ", vim.fn.getcwd(), "dir")
        end,
      },
    }

    vim.keymap.set("n", "<F5>",       dap.continue,          { desc = "Debug: continue" })
    vim.keymap.set("n", "<F10>",      dap.step_over,         { desc = "Debug: step over" })
    vim.keymap.set("n", "<F11>",      dap.step_into,         { desc = "Debug: step into" })
    vim.keymap.set("n", "<F12>",      dap.step_out,          { desc = "Debug: step out" })
    vim.keymap.set("n", "<leader>db", dap.toggle_breakpoint, { desc = "Debug: toggle breakpoint" })
    vim.keymap.set("n", "<leader>dc", dap.continue,          { desc = "Debug: continue" })
    vim.keymap.set("n", "<leader>du", dapui.toggle,          { desc = "Debug: toggle UI" })
  end,
}
