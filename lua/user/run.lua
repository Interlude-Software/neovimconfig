-- Launch this project's built executables from inside Neovim, with saved
-- argument profiles and a streaming log window per run.
--
-- Profiles live in .nvim-run.json at the project root, so they are committed and
-- shared. Recency ordering is machine-local and kept in stdpath("cache") instead
-- — putting "last launched" timestamps in the committed file would dirty the
-- working tree on every launch.
--
-- Several runs can be in flight at once (a host and a client, say). Each gets its
-- own log buffer; output is parsed for the "[tag] [LVL] message" shape so the
-- view can be filtered down to errors and warnings.
--
-- Not a plugin spec: see the note at the top of user/build.lua.

local M = {}

local uv = vim.uv or vim.loop

local PROFILE_FILE = ".nvim-run.json"
local RECENT_STATE = vim.fn.stdpath("cache") .. "/nvim_run_recent.json"
local FLUSH_MS = 60 -- batch appends; a chatty game would thrash the buffer otherwise
local NS = vim.api.nvim_create_namespace("user_run")

-- Ranks order the level filter: showing warnings implies showing errors.
local LEVELS = {
  ERR = { rank = 4, hl = "DiagnosticError" },
  WRN = { rank = 3, hl = "DiagnosticWarn" },
  INF = { rank = 2, hl = "DiagnosticInfo" },
  VRB = { rank = 1, hl = "Comment" },
}

local FILTERS = {
  all = { min = 0, label = "all" },
  warn = { min = 3, label = "ERR+WRN" },
  err = { min = 4, label = "ERR" },
}

local runs = {} -- id -> instance
local next_id = 1

------------------------------------------------------------------- storage --

local function read_json(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local content = fd:read("*a")
  fd:close()
  local ok, data = pcall(vim.json.decode, content)
  return ok and data or nil
end

local function find_up(name)
  local from = vim.api.nvim_buf_get_name(0)
  from = (from ~= "" and uv.fs_stat(from)) and vim.fs.dirname(from) or vim.fn.getcwd()
  return vim.fs.find(name, { path = from, upward = true })[1]
end

--- Root is wherever the profile file lives; failing that, the CMake root, so a
--- project with no profiles yet still resolves somewhere sensible.
local function project_root()
  local found = find_up(PROFILE_FILE)
  if found then
    return vim.fs.dirname(found)
  end
  local ok, build = pcall(require, "user.build")
  if ok then
    local root = build.project_root()
    if root then
      return root
    end
  end
  return vim.fn.getcwd()
end

local function profile_path(root)
  return root .. "/" .. PROFILE_FILE
end

local function load_profiles(root)
  local data = read_json(profile_path(root))
  if type(data) == "table" and type(data.profiles) == "table" then
    return data.profiles
  end
  return {}
end

--- vim.json.encode emits {} for an empty Lua table, so an argument-less profile
--- would be written as "args": {} and read back as an object. Arrays are built by
--- hand, which also keeps the committed file pretty-printed and reviewable
--- without shelling out to a formatter.
local function json_array(list)
  if not list or #list == 0 then
    return "[]"
  end
  local parts = vim.tbl_map(function(v)
    return vim.json.encode(v)
  end, list)
  return "[" .. table.concat(parts, ", ") .. "]"
end

local function save_profiles(root, profiles)
  local lines = { "{", '  "profiles": [' }
  for i, p in ipairs(profiles) do
    local fields = {
      string.format('      "name": %s', vim.json.encode(p.name or "Run")),
      string.format('      "args": %s', json_array(p.args)),
    }
    for _, key in ipairs({ "exe", "cwd", "filter" }) do
      if p[key] and p[key] ~= "" then
        fields[#fields + 1] = string.format("      %q: %s", key, vim.json.encode(p[key]))
      end
    end
    if p.env and next(p.env) then
      fields[#fields + 1] = string.format('      "env": %s', vim.json.encode(p.env))
    end
    lines[#lines + 1] = "    {"
    lines[#lines + 1] = table.concat(fields, ",\n")
    lines[#lines + 1] = "    }" .. (i < #profiles and "," or "")
  end
  lines[#lines + 1] = "  ]"
  lines[#lines + 1] = "}"

  -- fields were joined with embedded newlines; writefile needs one entry per line
  local flat = vim.split(table.concat(lines, "\n"), "\n")
  vim.fn.writefile(flat, profile_path(root))
end

local function recents()
  return read_json(RECENT_STATE) or {}
end

local function touch_recent(root, name)
  local all = recents()
  all[root] = all[root] or {}
  all[root][name] = os.time()
  vim.fn.writefile({ vim.json.encode(all) }, RECENT_STATE)
end

--- Profiles most-recently-launched first, then never-launched ones by name.
local function sorted_profiles(root)
  local profiles = load_profiles(root)
  local seen = recents()[root] or {}
  local order = {}
  for i, p in ipairs(profiles) do
    order[p] = { at = seen[p.name] or 0, i = i }
  end
  table.sort(profiles, function(a, b)
    local ea, eb = order[a], order[b]
    if ea.at ~= eb.at then
      return ea.at > eb.at
    end
    return ea.i < eb.i
  end)
  return profiles
end

--------------------------------------------------------- executable lookup --

local function is_executable_file(path)
  local st = uv.fs_stat(path)
  if not st or st.type ~= "file" then
    return false
  end
  if path:match("%.dylib$") or path:match("%.so$") or path:match("%.dll$") or path:match("%.a$") then
    return false
  end
  return math.floor(st.mode / 64) % 2 == 1 -- owner execute bit
end

--- Executables produced by the build, newest first. CMake projects normally put
--- them in <binaryDir>/bin via CMAKE_RUNTIME_OUTPUT_DIRECTORY; the binary dir
--- itself is checked too for projects that do not set it.
local function built_executables()
  local ok, build = pcall(require, "user.build")
  local dir = ok and build.binary_dir()
  if not dir then
    return {}
  end

  local found = {}
  for _, sub in ipairs({ "/bin", "" }) do
    local scan = uv.fs_scandir(dir .. sub)
    while scan do
      local name, kind = uv.fs_scandir_next(scan)
      if not name then
        break
      end
      if kind ~= "directory" then
        local path = dir .. sub .. "/" .. name
        if is_executable_file(path) then
          found[#found + 1] = { path = path, mtime = uv.fs_stat(path).mtime.sec }
        end
      end
    end
    if #found > 0 then
      break
    end
  end

  table.sort(found, function(a, b)
    return a.mtime > b.mtime
  end)
  return vim.tbl_map(function(e)
    return e.path
  end, found)
end

--- Absolute path to the executable a profile should launch, or nil plus a reason.
local function resolve_exe(profile, root)
  if profile.exe and profile.exe ~= "" then
    local path = profile.exe
    if not path:match("^/") then
      path = root .. "/" .. path
    end
    if not uv.fs_stat(path) then
      return nil, "executable not found: " .. path .. " (build it first?)"
    end
    return path
  end

  local candidates = built_executables()
  if #candidates == 0 then
    return nil, 'no built executable found — build first, or set "exe" in ' .. PROFILE_FILE
  end
  return candidates[1]
end

--------------------------------------------------------------- log parsing --

--- Levels come through as "[tag] [LVL] message", tag optional. ANSI colour is
--- suppressed by the game when stdout is not a tty, but a run through a pty
--- would include it, so strip escapes regardless.
local function parse_line(raw)
  local text = raw:gsub("\27%[[%d;]*[A-Za-z]", "")
  local level = text:match("^%s*%[[^%]]*%]%s*%[(%u%u%u)%]") or text:match("^%s*%[(%u%u%u)%]")
  if level and not LEVELS[level] then
    level = nil
  end
  return { text = text, level = level }
end

------------------------------------------------------------- log rendering --

local function filter_of(inst)
  return FILTERS[inst.filter] or FILTERS.all
end

local function passes(inst, entry)
  local min = filter_of(inst).min
  if min == 0 then
    return true
  end
  local rank = entry.level and LEVELS[entry.level].rank or 0
  -- Unlevelled output (plain printf, SDL/Vulkan chatter) is only hidden once
  -- filtering is on, where it is noise by definition.
  return rank >= min
end

local function highlight(buf, lnum, entry)
  if not entry.level then
    return
  end
  local text = entry.text
  local tag_s, tag_e = text:find("%[[^%]]*%]")
  local lvl_s, lvl_e = text:find("%[" .. entry.level .. "%]")
  if tag_s and lvl_s and tag_s < lvl_s then
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, lnum, tag_s - 1, {
      end_col = tag_e,
      hl_group = "Comment",
    })
  end
  if lvl_s then
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, lnum, lvl_s - 1, {
      end_col = lvl_e,
      hl_group = LEVELS[entry.level].hl,
    })
  end
end

local function update_winbar(inst)
  if not (inst.buf and vim.api.nvim_buf_is_valid(inst.buf)) then
    return
  end
  local status = inst.status == "running" and "running" or ("exited " .. tostring(inst.code))
  local bar = string.format(
    "  %s  ·  %s  ·  %d ERR  %d WRN  ·  filter: %s%s",
    inst.name,
    status,
    inst.errors,
    inst.warnings,
    filter_of(inst).label,
    inst.follow and "  ·  following" or ""
  )
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == inst.buf then
      vim.wo[win].winbar = bar:gsub("%%", "%%%%")
    end
  end
end

local function at_end(win, buf)
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  return lnum >= vim.api.nvim_buf_line_count(buf) - 1
end

local function scroll_to_end(inst)
  if not inst.follow then
    return
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == inst.buf then
      local last = vim.api.nvim_buf_line_count(inst.buf)
      pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
    end
  end
end

local function buf_write(inst, entries, replace_all)
  local buf = inst.buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end

  local texts = vim.tbl_map(function(e)
    return e.text
  end, entries)

  vim.bo[buf].modifiable = true
  local first
  if replace_all then
    vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, #texts > 0 and texts or { "" })
    first = 0
  else
    local count = vim.api.nvim_buf_line_count(buf)
    local blank = count == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
    first = blank and 0 or count
    vim.api.nvim_buf_set_lines(buf, first, blank and 1 or count, false, texts)
  end
  for i, entry in ipairs(entries) do
    highlight(buf, first + i - 1, entry)
  end
  vim.bo[buf].modifiable = false
end

local function rerender(inst)
  local visible = vim.tbl_filter(function(e)
    return passes(inst, e)
  end, inst.lines)
  buf_write(inst, visible, true)
  update_winbar(inst)
  scroll_to_end(inst)
end

--- Drain what the process wrote since the last tick. Runs on a timer rather than
--- per-chunk: a verbose game can emit thousands of lines a second, and touching
--- the buffer for each one stalls the editor.
local function flush(inst)
  if #inst.pending == 0 then
    return
  end
  local batch = inst.pending
  inst.pending = {}

  local appended = {}
  for _, raw in ipairs(batch) do
    local entry = parse_line(raw)
    inst.lines[#inst.lines + 1] = entry
    if entry.level == "ERR" then
      inst.errors = inst.errors + 1
    elseif entry.level == "WRN" then
      inst.warnings = inst.warnings + 1
    end
    if passes(inst, entry) then
      appended[#appended + 1] = entry
    end
  end

  if #appended > 0 then
    buf_write(inst, appended, false)
    scroll_to_end(inst)
  end
  update_winbar(inst)
  vim.cmd("redrawstatus")
end

------------------------------------------------------------- log window UI --

local function set_filter(inst, name)
  inst.filter = name
  rerender(inst)
end

local function open_window(inst, focus)
  if not vim.api.nvim_buf_is_valid(inst.buf) then
    return
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == inst.buf then
      if focus then
        vim.api.nvim_set_current_win(win)
      end
      return
    end
  end

  local prev = vim.api.nvim_get_current_win()
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, inst.buf)
  vim.api.nvim_win_set_height(0, math.max(10, math.floor(vim.o.lines * 0.35)))
  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.wrap = false
  update_winbar(inst)
  scroll_to_end(inst)
  if not focus then
    vim.api.nvim_set_current_win(prev)
  end
end

local function setup_buffer(inst)
  local buf = vim.api.nvim_create_buf(false, true)
  inst.buf = buf
  vim.api.nvim_buf_set_name(buf, string.format("run://%s#%d", inst.name, inst.id))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "runlog"
  vim.bo[buf].modifiable = false

  local map = function(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, desc = desc, nowait = true })
  end
  map("a", function()
    set_filter(inst, "all")
  end, "Show all output")
  map("w", function()
    set_filter(inst, "warn")
  end, "Show errors and warnings")
  map("e", function()
    set_filter(inst, "err")
  end, "Show errors only")
  map("f", function()
    inst.follow = not inst.follow
    update_winbar(inst)
    scroll_to_end(inst)
  end, "Toggle follow")
  map("x", function()
    M.stop(inst.id)
  end, "Stop this run")
  map("r", function()
    M.restart(inst.id)
  end, "Restart this run")
  map("q", function()
    vim.cmd("close")
  end, "Close log window")

  -- Follow tracks the cursor: reading back through history pauses tailing,
  -- returning to the bottom resumes it. No keypress needed for the common case.
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_buf(win) ~= buf then
        return
      end
      local following = at_end(win, buf)
      if following ~= inst.follow then
        inst.follow = following
        update_winbar(inst)
      end
    end,
  })
end

------------------------------------------------------------------ launching --

local function line_sink(inst)
  local partial = ""
  return function(_, chunk)
    if not chunk then
      if partial ~= "" then
        inst.pending[#inst.pending + 1] = partial
        partial = ""
      end
      return
    end
    partial = partial .. chunk
    local from = 1
    while true do
      local nl = partial:find("\n", from, true)
      if not nl then
        break
      end
      inst.pending[#inst.pending + 1] = (partial:sub(from, nl - 1):gsub("\r$", ""))
      from = nl + 1
    end
    partial = partial:sub(from)
  end
end

local function launch(profile, root)
  local exe, err = resolve_exe(profile, root)
  if not exe then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  local cmd = { exe }
  vim.list_extend(cmd, profile.args or {})

  local inst = {
    id = next_id,
    name = profile.name or vim.fs.basename(exe),
    profile = profile,
    root = root,
    lines = {},
    pending = {},
    errors = 0,
    warnings = 0,
    status = "running",
    code = nil,
    filter = profile.filter or "all",
    follow = true,
  }
  next_id = next_id + 1
  runs[inst.id] = inst

  setup_buffer(inst)
  open_window(inst, false)

  local cwd = profile.cwd
  if cwd and not cwd:match("^/") then
    cwd = root .. "/" .. cwd
  end

  local sink = line_sink(inst)
  inst.job = vim.system(cmd, {
    -- Project root, not the exe's directory: a game in development resolves its
    -- data (scripts/, assets/) relative to the repo, and the build dir only ever
    -- holds whatever CMake happened to copy there. This is also what you get
    -- launching from a shell at the project root, which is the habit being
    -- replaced. Override per profile with "cwd".
    cwd = cwd or root,
    env = profile.env,
    stdout = sink,
    stderr = sink,
    stdin = false, -- so a --wait-for-enter style prompt sees EOF instead of hanging
    text = true,
  }, function(res)
    vim.schedule(function()
      inst.status = "exited"
      inst.code = res.code
      inst.job = nil
      flush(inst)
      if inst.timer then
        inst.timer:stop()
        inst.timer:close()
        inst.timer = nil
      end
      update_winbar(inst)
      vim.cmd("redrawstatus")
      local level = res.code == 0 and vim.log.levels.INFO or vim.log.levels.WARN
      vim.notify(
        string.format("%s exited (%d) — %d ERR %d WRN", inst.name, res.code, inst.errors, inst.warnings),
        level
      )
    end)
  end)

  inst.timer = uv.new_timer()
  inst.timer:start(
    FLUSH_MS,
    FLUSH_MS,
    vim.schedule_wrap(function()
      flush(inst)
    end)
  )

  touch_recent(root, inst.name)
  vim.notify("running " .. inst.name .. ": " .. table.concat(cmd, " ", 2))
  return inst
end

----------------------------------------------------------------- commands --

local function active()
  local list = {}
  for _, inst in pairs(runs) do
    list[#list + 1] = inst
  end
  table.sort(list, function(a, b)
    return a.id < b.id
  end)
  return list
end

--- Pick a profile and launch it. With no profiles yet, offers to create one.
function M.pick()
  local root = project_root()
  local profiles = sorted_profiles(root)
  if #profiles == 0 then
    vim.notify("no run profiles yet — creating one", vim.log.levels.INFO)
    M.new_profile()
    return
  end

  local items = vim.tbl_map(function(p)
    local args = table.concat(p.args or {}, " ")
    return args ~= "" and (p.name .. "  —  " .. args) or p.name
  end, profiles)

  vim.ui.select(items, { prompt = "Run profile:" }, function(_, idx)
    if idx then
      launch(profiles[idx], root)
    end
  end)
end

--- Re-launch the most recent profile without asking.
function M.again()
  local root = project_root()
  local profiles = sorted_profiles(root)
  if #profiles == 0 then
    return M.pick()
  end
  launch(profiles[1], root)
end

function M.new_profile()
  local root = project_root()
  local suggested = built_executables()[1]

  vim.ui.input({ prompt = "Profile name: " }, function(name)
    if not name or name == "" then
      return
    end
    vim.ui.input({ prompt = "Arguments: " }, function(args)
      if args == nil then
        return
      end
      vim.ui.input({
        prompt = "Executable (blank = auto-detect): ",
        default = "",
      }, function(exe)
        if exe == nil then
          return
        end
        local profiles = load_profiles(root)
        profiles[#profiles + 1] = {
          name = name,
          args = vim.split(vim.trim(args), "%s+", { trimempty = true }),
          exe = exe ~= "" and exe or nil,
        }
        save_profiles(root, profiles)
        vim.notify(
          ("saved profile %q to %s%s"):format(
            name,
            PROFILE_FILE,
            suggested and ("\nauto-detected exe: " .. vim.fn.fnamemodify(suggested, ":~:.")) or ""
          )
        )
      end)
    end)
  end)
end

function M.edit_profiles()
  local root = project_root()
  local path = profile_path(root)
  if not uv.fs_stat(path) then
    save_profiles(root, {
      {
        name = "Run",
        args = {},
        exe = nil,
        cwd = nil,
      },
    })
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
end

--- Jump to a run's log window.
function M.logs()
  local list = active()
  if #list == 0 then
    vim.notify("nothing has been run yet", vim.log.levels.INFO)
    return
  end
  if #list == 1 then
    open_window(list[1], true)
    return
  end
  local items = vim.tbl_map(function(inst)
    return string.format(
      "%s#%d  %s  %d ERR %d WRN",
      inst.name,
      inst.id,
      inst.status == "running" and "running" or ("exit " .. tostring(inst.code)),
      inst.errors,
      inst.warnings
    )
  end, list)
  vim.ui.select(items, { prompt = "Run log:" }, function(_, idx)
    if idx then
      open_window(list[idx], true)
    end
  end)
end

function M.stop(id)
  local inst = runs[id]
  if inst and inst.job then
    inst.job:kill(15)
    return true
  end
  return false
end

--- Stop a running instance, or all of them when several are live.
function M.stop_pick()
  local live = vim.tbl_filter(function(inst)
    return inst.job ~= nil
  end, active())

  if #live == 0 then
    vim.notify("no runs in flight", vim.log.levels.INFO)
    return
  end
  if #live == 1 then
    M.stop(live[1].id)
    return
  end

  local items = vim.tbl_map(function(inst)
    return inst.name .. "#" .. inst.id
  end, live)
  table.insert(items, "── stop all ──")
  vim.ui.select(items, { prompt = "Stop run:" }, function(_, idx)
    if not idx then
      return
    end
    if idx > #live then
      for _, inst in ipairs(live) do
        M.stop(inst.id)
      end
    else
      M.stop(live[idx].id)
    end
  end)
end

function M.restart(id)
  local inst = runs[id]
  if not inst then
    return
  end
  local profile, root = inst.profile, inst.root
  if inst.job then
    inst.job:kill(15)
  end
  -- The old buffer stays as history; a restart is a new instance.
  launch(profile, root)
end

--- lualine component: live totals across every run.
function M.statusline()
  local live, errors, warnings, name = 0, 0, 0, nil
  for _, inst in pairs(runs) do
    if inst.job then
      live = live + 1
      name = inst.name
    end
    errors = errors + inst.errors
    warnings = warnings + inst.warnings
  end
  if live == 0 then
    return ""
  end
  local head = live == 1 and ("▶ " .. name) or string.format("▶ %d runs", live)
  if errors > 0 or warnings > 0 then
    return string.format("%s %dE %dW", head, errors, warnings)
  end
  return head
end

function M.statusline_hl()
  for _, inst in pairs(runs) do
    if inst.errors > 0 then
      return "DiagnosticError"
    end
  end
  return nil
end

function M.setup()
  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { desc = desc })
  end

  map("<leader>br", M.pick, "Run profile")
  map("<leader>bR", M.again, "Re-run last profile")
  map("<leader>bn", M.new_profile, "New run profile")
  map("<leader>be", M.edit_profiles, "Edit run profiles")
  map("<leader>bg", M.logs, "Go to run log")
  map("<leader>bk", M.stop_pick, "Stop a run")

  vim.api.nvim_create_user_command("Run", function(cmd)
    if cmd.args == "" then
      M.pick()
      return
    end
    local root = project_root()
    for _, p in ipairs(load_profiles(root)) do
      if p.name == cmd.args then
        launch(p, root)
        return
      end
    end
    vim.notify("no profile named " .. cmd.args, vim.log.levels.ERROR)
  end, {
    nargs = "?",
    desc = "Launch a run profile",
    complete = function()
      return vim.tbl_map(function(p)
        return p.name
      end, load_profiles(project_root()))
    end,
  })

  -- Child processes would otherwise outlive the editor that spawned them.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      for _, inst in pairs(runs) do
        if inst.job then
          pcall(function()
            inst.job:kill(15)
          end)
        end
      end
    end,
  })
end

return M
