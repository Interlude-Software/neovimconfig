return {
  "mfussenegger/nvim-dap",
  dependencies = {
    "rcarriga/nvim-dap-ui",
    "nvim-neotest/nvim-nio",
    "theHamsta/nvim-dap-virtual-text",
  },
  config = function()
    local dap = require("dap")
    local dapui = require("dapui")

    dapui.setup()
    require("nvim-dap-virtual-text").setup()

    local function clear_virtual_text()
      vim.schedule(function()
        local ns = vim.api.nvim_get_namespaces()["nvim-dap-virtual-text"]
        if ns then
          for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(buf) then
              vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
            end
          end
        end
      end)
    end

    dap.listeners.after.event_initialized["dapui_config"] = dapui.open
    dap.listeners.before.event_terminated["dapui_config"] = function() dapui.close(); clear_virtual_text() end
    dap.listeners.before.event_exited["dapui_config"] = function() dapui.close(); clear_virtual_text() end
    dap.listeners.after.disconnect["dapui_config"] = function() dapui.close(); clear_virtual_text() end

    local adapter_dll = vim.fn.glob(
      vim.fn.expand("~/.vscode/extensions/visualstudiotoolsforunity.vstuc-*/bin/UnityDebugAdapter.dll")
    )

    dap.adapters.vstuc = {
      type = "executable",
      command = "dotnet",
      args = { adapter_dll },
    }

    dap.adapters.coreclr = {
      type = "executable",
      command = vim.fn.expand("~/.local/share/nvim/mason/bin/netcoredbg"),
      args = { "--interpreter=vscode" },
    }

    -- Unity discovery helpers

    local function unity_project_path(pid)
      local args = vim.fn.trim(vim.fn.system("ps -p " .. pid .. " -o args="))
      local s, e = args:lower():find("%-projectpath%s+")
      if not s then return nil end
      local rest = args:sub(e + 1)
      return rest:match("(.-)%s+%-%a") or rest:match("(.+)$")
    end

    local cache_file = vim.fn.stdpath("cache") .. "/unity_debug_project.txt"

    local function load_cached_project()
      local f = io.open(cache_file, "r")
      if not f then return nil end
      local v = vim.fn.trim(f:read("*a"))
      f:close()
      return v ~= "" and v or nil
    end

    local function save_cached_project(project)
      local f = io.open(cache_file, "w")
      if f then f:write(project); f:close() end
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

    -- Resolve a Unity endpoint, always showing the instance picker
    local function unity_endpoint_pick()
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
      save_cached_project(entry.project)
      return entry.addr
    end

    -- Resolve a Unity endpoint using the cached project, falling back to pick
    local function unity_endpoint_cached(cached_project)
      local entries = discover_unity()
      if #entries == 0 then
        vim.notify("No Unity debug ports found — is the Editor running?", vim.log.levels.ERROR)
        return nil
      end
      -- Reuse session selection if port is still alive
      if unity_selection then
        for _, e in ipairs(entries) do
          if e.addr == unity_selection.addr then
            return unity_selection.addr
          end
        end
        unity_selection = nil
      end
      -- Auto-select by cached project
      local matches = vim.tbl_filter(function(e) return e.project == cached_project end, entries)
      if #matches >= 1 then
        unity_selection = matches[1]
        return matches[1].addr
      end
      -- Project not running, fall back to full picker
      return unity_endpoint_pick()
    end

    -- Build config list dynamically so Re-attach only appears when relevant
    local function build_configs()
      local configs = {}
      local cached = load_cached_project()

      if cached then
        table.insert(configs, {
          type    = "vstuc",
          request = "attach",
          name    = "Re-attach  [" .. vim.fn.fnamemodify(cached, ":t") .. "]",
          endPoint    = function() return unity_endpoint_cached(cached) end,
          projectPath = function()
            return (unity_selection and unity_selection.project) or cached
          end,
        })
      end

      table.insert(configs, {
        type    = "vstuc",
        request = "attach",
        name    = "Attach to Unity Editor",
        endPoint    = function() return unity_endpoint_pick() end,
        projectPath = function()
          if unity_selection then return unity_selection.project end
          local pids = vim.fn.systemlist("pgrep -x Unity 2>/dev/null")
          if #pids == 1 then
            local path = unity_project_path(vim.fn.trim(pids[1]))
            if path then return path end
          end
          return vim.fn.input("Unity project path: ", vim.fn.getcwd(), "dir")
        end,
      })

      table.insert(configs, {
        type    = "coreclr",
        request = "launch",
        name    = "Launch .NET App",
        program = function()
          return vim.fn.input("Path to DLL: ", vim.fn.getcwd() .. "/bin/Debug/", "file")
        end,
      })

      table.insert(configs, {
        type      = "coreclr",
        request   = "attach",
        name      = "Attach to .NET Process",
        processId = require("dap.utils").pick_process,
      })

      return configs
    end

    local function start_debug()
      local configs = build_configs()
      local entry
      if #configs == 1 then
        entry = configs[1]
      else
        local labels = { "Select debug configuration:" }
        for i, c in ipairs(configs) do
          table.insert(labels, i .. ". " .. c.name)
        end
        local choice = vim.fn.inputlist(labels)
        if choice < 1 or choice > #configs then return end
        entry = configs[choice]
      end
      dap.run(entry)
    end

    vim.keymap.set("n", "<F5>", function()
      if dap.session() then dap.continue() else start_debug() end
    end, { desc = "Debug: continue / start" })
    vim.keymap.set("n", "<F10>",      dap.step_over,         { desc = "Debug: step over" })
    vim.keymap.set("n", "<F11>",      dap.step_into,         { desc = "Debug: step into" })
    vim.keymap.set("n", "<F12>",      dap.step_out,          { desc = "Debug: step out" })
    vim.keymap.set("n", "<leader>db", dap.toggle_breakpoint, { desc = "Debug: toggle breakpoint" })
    vim.keymap.set("n", "<leader>dc", function()
      if dap.session() then dap.continue() else start_debug() end
    end, { desc = "Debug: continue / start" })
    vim.keymap.set("n", "<leader>dh", function() dapui.eval() end, { desc = "Debug: hover eval" })
    vim.keymap.set("v", "<leader>dh", function() dapui.eval() end, { desc = "Debug: eval selection" })
    vim.keymap.set("n", "<leader>du", function()
      dapui.toggle()
      if not dap.session() then clear_virtual_text() end
    end, { desc = "Debug: toggle UI" })
  end,
}
