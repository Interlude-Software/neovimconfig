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

local function is_dir(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == "directory"
end

local function profile_path(root)
  return root .. "/" .. PROFILE_FILE
end

local function load_config(root)
  local data = read_json(profile_path(root))
  if type(data) ~= "table" then
    return { options = {}, profiles = {} }
  end
  return {
    options = type(data.options) == "table" and data.options or {},
    profiles = type(data.profiles) == "table" and data.profiles or {},
  }
end

local function load_profiles(root)
  return load_config(root).profiles
end

--- The option schema: what command-line switches this project understands, so the
--- profile form can offer checkboxes and typed fields instead of a raw string.
--- Maintained by hand — nothing here can discover an executable's real flags.
local function load_options(root)
  return load_config(root).options
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

--- Writing must round-trip the option schema, not just the profiles: saving a
--- profile would otherwise silently delete the very definitions the form is
--- built from.
local function save_profiles(root, profiles, options)
  options = options or load_options(root)

  local lines = { "{" }

  if #options > 0 then
    lines[#lines + 1] = '  "options": ['
    for i, opt in ipairs(options) do
      local fields = {
        string.format('      "flag": %s', vim.json.encode(opt.flag)),
        string.format('      "type": %s', vim.json.encode(opt.type or "string")),
      }
      if opt.label and opt.label ~= "" then
        fields[#fields + 1] = string.format('      "label": %s', vim.json.encode(opt.label))
      end
      if opt.values and #opt.values > 0 then
        fields[#fields + 1] = string.format('      "values": %s', json_array(opt.values))
      end
      lines[#lines + 1] = "    {"
      lines[#lines + 1] = table.concat(fields, ",\n")
      lines[#lines + 1] = "    }" .. (i < #options and "," or "")
    end
    lines[#lines + 1] = "  ],"
  end

  lines[#lines + 1] = '  "profiles": ['
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

--- Carry a profile's launch history across a rename; recency is keyed by name, so
--- renaming would otherwise drop a frequently-used profile to the bottom.
local function rename_recent(root, from, to)
  if from == to or not from then
    return
  end
  local all = recents()
  local per_project = all[root]
  if not per_project or per_project[from] == nil then
    return
  end
  per_project[to] = per_project[from]
  per_project[from] = nil
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
local function built_executables(root)
  local ok, build = pcall(require, "user.build")
  local dir = ok and build.binary_dir(root)
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

-- Directories under a build tree that only ever hold build machinery.
local SKIP_SCAN = { CMakeFiles = true, [".cmake"] = true, Testing = true }

local function scan_executables(dir, depth, out, seen)
  local scan = uv.fs_scandir(dir)
  if not scan then
    return
  end
  while true do
    local name, kind = uv.fs_scandir_next(scan)
    if not name then
      break
    end
    local path = dir .. "/" .. name
    if kind == "directory" then
      if depth > 0 and not SKIP_SCAN[name] then
        scan_executables(path, depth - 1, out, seen)
      end
    elseif not seen[path] and is_executable_file(path) then
      seen[path] = true
      out[#out + 1] = { path = path, mtime = uv.fs_stat(path).mtime.sec, size = uv.fs_stat(path).size }
    end
  end
end

--- Every executable under the build tree, newest first — a wider net than
--- built_executables(), which stays narrow because it feeds auto-detection and
--- must not start picking up test harnesses or tools just because they are newer.
--- This one only populates a picker, where more candidates is strictly better.
local function all_executables(root)
  local ok, build = pcall(require, "user.build")
  local dir = ok and build.binary_dir(root)
  if not dir then
    return {}
  end
  local found, seen = {}, {}
  scan_executables(dir, 2, found, seen)
  table.sort(found, function(a, b)
    return a.mtime > b.mtime
  end)
  return found
end

local function human_size(bytes)
  if bytes >= 1024 * 1024 then
    return string.format("%.1f MB", bytes / 1024 / 1024)
  end
  return string.format("%.0f KB", math.max(bytes / 1024, 1))
end

local function human_age(mtime)
  local seconds = os.time() - mtime
  if seconds < 90 then
    return "just now"
  elseif seconds < 3600 then
    return string.format("%dm ago", math.floor(seconds / 60))
  elseif seconds < 86400 then
    return string.format("%dh ago", math.floor(seconds / 3600))
  end
  return os.date("%d %b", mtime)
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

  local candidates = built_executables(root)
  if #candidates == 0 then
    return nil, 'no built executable found — build first, or set "exe" in ' .. PROFILE_FILE
  end
  return candidates[1]
end

------------------------------------------------------------- profile form --

local FILTER_VALUES = { "all", "warn", "err" }
local OPTION_PREFIX = "opt:" -- namespaces schema fields away from name/exe/cwd

--- Split a profile's argument list back into schema values plus whatever the
--- schema does not describe. Editing must not quietly drop hand-written args, so
--- anything unrecognised survives in a free-text field.
local function split_args(args, options)
  local by_flag = {}
  for _, opt in ipairs(options) do
    by_flag[opt.flag] = opt
  end

  local values, extra = {}, {}
  local i = 1
  while i <= (args and #args or 0) do
    local token = args[i]
    local flag, inline = token:match("^([^=]+)=(.*)$")
    local opt = by_flag[flag or token]

    if opt and opt.type == "bool" then
      values[opt.flag] = true
    elseif opt and inline then
      values[opt.flag] = inline
    elseif opt then
      values[opt.flag] = args[i + 1]
      i = i + 1
    else
      extra[#extra + 1] = token
    end
    i = i + 1
  end
  return values, extra
end

local function build_fields(profile, options, root)
  local values, extra = split_args(profile.args, options)

  local fields = {
    { kind = "section", label = "Profile" },
    { kind = "text", key = "name", label = "Name", value = profile.name or "", required = true },
  }

  -- Checkboxes before valued fields: a wall of mixed rows is harder to scan.
  local flags, valued = {}, {}
  for _, opt in ipairs(options) do
    local field = {
      key = OPTION_PREFIX .. opt.flag,
      label = (opt.label and opt.label ~= "") and opt.label or opt.flag,
      flag = opt.flag,
      kind = opt.type == "bool" and "bool" or opt.type == "int" and "int" or opt.type == "enum" and "enum" or "text",
      values = opt.values,
      value = values[opt.flag],
    }
    if field.kind == "bool" then
      field.value = values[opt.flag] == true
      flags[#flags + 1] = field
    else
      valued[#valued + 1] = field
    end
  end

  if #flags > 0 then
    fields[#fields + 1] = { kind = "section", label = "Flags" }
    vim.list_extend(fields, flags)
  end
  if #valued > 0 then
    fields[#fields + 1] = { kind = "section", label = "Values" }
    vim.list_extend(fields, valued)
  end

  fields[#fields + 1] = { kind = "section", label = "Advanced" }
  -- Defaults belong in the placeholder, not the label: a label wide enough to
  -- explain itself pushes the value column off to the right.
  fields[#fields + 1] = {
    kind = "text",
    key = "extra",
    label = "Extra args",
    value = table.concat(extra, " "),
    placeholder = "(none)",
  }
  fields[#fields + 1] = {
    kind = "choice",
    key = "exe",
    label = "Executable",
    value = profile.exe or "",
    placeholder = "(auto-detect newest)",
    -- Evaluated when the field is opened, not when the form is built: a build
    -- finishing while the form sits open should show up in the list.
    values_fn = function()
      local items = { { label = "(auto-detect newest built executable)", value = "" } }
      for _, entry in ipairs(all_executables(root)) do
        local shown = entry.path
        if shown:sub(1, #root + 1) == root .. "/" then
          shown = shown:sub(#root + 2)
        end
        items[#items + 1] = {
          label = string.format("%s   %s, %s", shown, human_size(entry.size), human_age(entry.mtime)),
          value = shown,
        }
      end
      items[#items + 1] = { label = "Enter a path manually…", value = require("user.form").PROMPT }
      return items
    end,
  }
  fields[#fields + 1] = {
    kind = "text",
    key = "cwd",
    label = "Working dir",
    value = profile.cwd or "",
    placeholder = "(project root)",
  }
  fields[#fields + 1] =
    { kind = "enum", key = "filter", label = "Log filter", values = FILTER_VALUES, value = profile.filter or "all" }

  return fields
end

--- Rebuild the argument list in schema order, so a saved profile reads the same
--- way every time regardless of how it was edited.
local function args_from(values, options)
  local args = {}
  for _, opt in ipairs(options) do
    local value = values[OPTION_PREFIX .. opt.flag]
    if opt.type == "bool" then
      if value == true then
        args[#args + 1] = opt.flag
      end
    elseif value ~= nil and value ~= "" then
      args[#args + 1] = opt.flag
      args[#args + 1] = tostring(value)
    end
  end
  vim.list_extend(args, vim.split(vim.trim(values.extra or ""), "%s+", { trimempty = true }))
  return args
end

-- Everything the form owns. Any of these may legitimately become nil (an emptied
-- field), which is why merging an edit cannot go through vim.tbl_extend: a nil
-- carries no key, so the previous value would survive and the field could never
-- be cleared. Keys outside this set — `env`, anything hand-added — are preserved.
local FORM_KEYS = { "name", "args", "exe", "cwd", "filter" }

local function profile_from(values, options)
  return {
    name = vim.trim(values.name or ""),
    args = args_from(values, options),
    exe = values.exe ~= "" and values.exe or nil,
    cwd = values.cwd ~= "" and values.cwd or nil,
    filter = values.filter ~= "all" and values.filter or nil,
  }
end

--- Apply an edited profile over the stored one, clearing what the form cleared.
local function merge_profile(existing, built)
  local merged = vim.deepcopy(existing or {})
  for _, key in ipairs(FORM_KEYS) do
    merged[key] = built[key] -- assigning nil removes the key
  end
  return merged
end

--- Open the form for `profile`; `index` nil means append a new one.
local function open_form(root, profile, index)
  local options = load_options(root)
  local form = require("user.form")

  form.open({
    title = index and ("Edit profile: " .. (profile.name or "")) or "New run profile",
    fields = build_fields(profile, options, root),
    preview = function(state)
      local values = {}
      for _, field in ipairs(state.fields) do
        if field.key then
          values[field.key] = field.value
        end
      end
      local args = args_from(values, options)
      local exe = values.exe ~= "" and values.exe or vim.fs.basename(built_executables(root)[1] or "<exe>")
      return "→ " .. exe .. " " .. table.concat(args, " ")
    end,
    on_submit = function(values)
      local built = profile_from(values, options)
      if built.name == "" then
        vim.notify("profile needs a name", vim.log.levels.ERROR)
        return false -- keeps the form open with everything else intact
      end
      local profiles = load_profiles(root)
      if index then
        rename_recent(root, profiles[index] and profiles[index].name, built.name)
        profiles[index] = merge_profile(profiles[index], built)
      else
        profiles[#profiles + 1] = built
      end
      save_profiles(root, profiles, options)
      vim.notify(("saved %q — %s"):format(built.name, table.concat(built.args, " ")))
    end,
  })

  if #options == 0 then
    vim.notify(
      'no "options" schema in ' .. PROFILE_FILE .. " yet — add one for checkboxes and typed fields",
      vim.log.levels.WARN
    )
  end
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
  open_form(project_root(), { args = {} }, nil)
end

--- Edit an existing profile in the form.
function M.edit_profile()
  local root = project_root()
  local profiles = load_profiles(root)
  if #profiles == 0 then
    return M.new_profile()
  end

  local items = vim.tbl_map(function(p)
    return p.name .. "  —  " .. table.concat(p.args or {}, " ")
  end, profiles)

  vim.ui.select(items, { prompt = "Edit profile:" }, function(_, idx)
    if idx then
      open_form(root, profiles[idx], idx)
    end
  end)
end

--- Open the raw config, for editing the option schema itself.
function M.edit_config()
  local root = project_root()
  local path = profile_path(root)
  if not uv.fs_stat(path) then
    -- Seed a schema skeleton: the form has nothing to show without one, and the
    -- shape is easier to copy than to recall.
    vim.fn.writefile({
      "{",
      '  "options": [',
      '    { "flag": "--headless", "type": "bool", "label": "Headless" },',
      '    { "flag": "--seed", "type": "int", "label": "Seed" },',
      '    { "flag": "--name", "type": "string", "label": "Name" },',
      '    { "flag": "--log-level", "type": "enum", "label": "Log level",',
      '      "values": ["error", "warning", "info", "verbose"] }',
      "  ],",
      '  "profiles": []',
      "}",
    }, path)
    vim.notify("created " .. PROFILE_FILE .. " — edit the options to match your executable")
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
end

------------------------------------------------------------- schema drift --

-- The option schema is hand-maintained, so it silently rots as flags are added
-- to the program. This finds quoted "--flag" literals in the source and diffs
-- them against the schema. It is a grep, not a parser: it cannot know a flag's
-- real type, and a flag built by string concatenation is invisible to it.

local SOURCE_DIRS = { "src", "source", "Source", "lib", "app" }

local function scan_paths(root)
  local paths = {}
  for _, name in ipairs(SOURCE_DIRS) do
    if is_dir(root .. "/" .. name) then
      paths[#paths + 1] = name
    end
  end
  if #paths == 0 then
    paths = { "." }
  end
  return paths
end

--- flag -> { file, lnum, takes_value } for every quoted --flag in the sources.
local function flags_in_source(root)
  if vim.fn.executable("rg") ~= 1 then
    vim.notify("ripgrep (rg) is needed to scan for flags", vim.log.levels.ERROR)
    return nil
  end

  local cmd = {
    "rg",
    "--no-heading",
    "--line-number",
    "--with-filename",
    "--glob=!build*",
    "--glob=!external",
    "--glob=!third_party",
    '"--[a-zA-Z][a-zA-Z0-9-]*"',
  }
  vim.list_extend(cmd, scan_paths(root))

  local res = vim.system(cmd, { cwd = root, text = true }):wait()
  -- rg exits 1 when it simply found nothing, which is not an error here
  if res.code > 1 then
    vim.notify("rg failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
    return nil
  end

  local found = {}
  for line in (res.stdout or ""):gmatch("[^\n]+") do
    local file, lnum, text = line:match("^([^:]+):(%d+):(.*)$")
    if file then
      -- A flag that consumes the next argv entry is a value option; a bare
      -- comparison is a switch. Both idioms sit on the comparison line.
      local takes_value = text:find("argv%[%+%+i%]") ~= nil
        or text:find("i %+ 1 < argc") ~= nil
        or text:find("i%+1 < argc") ~= nil
      -- A numeric conversion on the same line narrows "value" to "integer".
      local numeric = text:find("ato[il]") ~= nil or text:find("sto[iul]") ~= nil or text:find("strtou?l") ~= nil
      for flag in text:gmatch('"(%-%-[a-zA-Z][a-zA-Z0-9%-]*)"') do
        local existing = found[flag]
        if not existing then
          found[flag] = { file = file, lnum = tonumber(lnum), takes_value = takes_value, numeric = numeric }
        else
          -- A flag can be referenced in several places; the most specific
          -- observation wins so one bare mention does not downgrade it.
          existing.takes_value = existing.takes_value or takes_value
          existing.numeric = existing.numeric or numeric
        end
      end
    end
  end
  return found
end

--- The report text and the written type must agree, so both derive from here.
local function guess_type(where)
  if not where.takes_value then
    return "bool"
  end
  return where.numeric and "int" or "string"
end

local function describe(where)
  local kind = guess_type(where)
  return kind == "bool" and "a switch" or kind == "int" and "an integer" or "a value"
end

local function label_for(flag)
  local words = flag:gsub("^%-%-", ""):gsub("%-", " ")
  return (words:gsub("^%l", string.upper))
end

--- Diff the schema against the source. With `append`, missing flags are added to
--- the schema with a guessed type and the config is opened for review.
function M.scan_flags(append)
  local root = project_root()
  local found = flags_in_source(root)
  if not found then
    return
  end

  local options = load_options(root)
  local in_schema = {}
  for _, opt in ipairs(options) do
    in_schema[opt.flag] = true
  end

  local missing, stale = {}, {}
  for flag, where in pairs(found) do
    if not in_schema[flag] then
      missing[#missing + 1] = { flag = flag, where = where }
    end
  end
  table.sort(missing, function(a, b)
    return a.flag < b.flag
  end)
  for _, opt in ipairs(options) do
    if not found[opt.flag] then
      stale[#stale + 1] = opt.flag
    end
  end

  -- Missing flags go to the quickfix list so each one is jumpable to its usage.
  local items = {}
  for _, entry in ipairs(missing) do
    items[#items + 1] = {
      filename = root .. "/" .. entry.where.file,
      lnum = entry.where.lnum,
      text = string.format("%s  (not in schema — looks like %s)", entry.flag, describe(entry.where)),
      type = "W",
    }
  end
  vim.fn.setqflist({}, " ", { title = "run: flags missing from " .. PROFILE_FILE, items = items })

  local summary = string.format("%d flag(s) in source, %d missing from schema", vim.tbl_count(found), #missing)
  if #stale > 0 then
    summary = summary .. "\nnot found in source (stale?): " .. table.concat(stale, " ")
  end

  if #missing == 0 then
    vim.notify(summary .. " — schema is up to date")
    return
  end

  if not append then
    vim.notify(summary .. " — <leader>xq to review, :RunScanFlags! to add them", vim.log.levels.WARN)
    return
  end

  for _, entry in ipairs(missing) do
    options[#options + 1] = {
      flag = entry.flag,
      type = guess_type(entry.where),
      label = label_for(entry.flag),
    }
  end
  save_profiles(root, load_profiles(root), options)
  vim.notify(summary .. " — added; check the guessed types", vim.log.levels.WARN)
  vim.cmd("edit " .. vim.fn.fnameescape(profile_path(root)))
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
  map("<leader>be", M.edit_profile, "Edit run profile (form)")
  map("<leader>bE", M.edit_config, "Edit run config (raw JSON)")
  map("<leader>bg", M.logs, "Go to run log")
  map("<leader>bk", M.stop_pick, "Stop a run")
  map("<leader>bf", function()
    M.scan_flags(false)
  end, "Scan source for unlisted flags")

  vim.api.nvim_create_user_command("RunScanFlags", function(cmd)
    M.scan_flags(cmd.bang)
  end, { bang = true, desc = "Diff the option schema against --flags in the source (! to add missing)" })

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
