-- Async CMake/Make builds run from inside Neovim.
--
-- Output is parsed with 'errorformat' into the quickfix list, so compile errors
-- become a navigable list (<leader>xq renders it in Trouble, <CR> jumps to the
-- line) instead of text to eyeball in another tmux window. The raw output is
-- kept too, for failures no errorformat pattern catches — link errors, CMake
-- configure blowups — reachable with <leader>bo.
--
-- Not a plugin spec: lazy.nvim auto-imports lua/plugins/, which is why this
-- lives under lua/user/ and is required from init.lua.

local M = {}

local uv = vim.uv or vim.loop

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local OUTPUT_BUF_NAME = "build://output"

-- Build directories probed under the CMake source root, in order. The first one
-- that is actually configured wins (see is_configured); failing that, the first
-- that exists at all; failing that, "build" is created by the configure step.
local BUILD_DIRS = { "build", "out/build", "cmake-build-debug", "cmake-build-release" }

local state = {
  job = nil, -- vim.SystemObj of the step currently running
  queue = {}, -- steps still to run after the current one
  pending = nil, -- steps queued behind a build we are killing
  cancelled = false,
  status = nil, -- nil | "running" | "ok" | "failed" | "cancelled"
  errors = 0,
  warnings = 0,
  output = {}, -- raw stdout+stderr of the whole run
  label = "", -- short name shown in the statusline
  preset = nil, -- cmake preset in use, if any
  last = nil, -- steps of the last run, for a verbatim re-run
  start = 0,
  elapsed = 0,
  frame = 1,
  timer = nil,
}

--- gcc/clang diagnostics with the severity captured into the quickfix `type`
--- field, plus CMake's multi-line configure errors. Appended to the built-in
--- errorformat, which already handles make's directory tracking and the
--- "In file included from" noise.
local function errorformat()
  return table.concat({
    -- clang/gcc: match the specific severities first so %t is populated;
    -- anything else falls through to the built-in generic patterns.
    "%f:%l:%c: fatal %trror: %m",
    "%f:%l:%c: %trror: %m",
    "%f:%l:%c: %tarning: %m",
    "%f:%l:%c: %tote: %m",
    "%f:%l: fatal %trror: %m",
    "%f:%l: %trror: %m",
    "%f:%l: %tarning: %m",
    -- MSBuild/csc, for a vim.g.build_command of "dotnet build". The escaped
    -- comma separates line from column; the built-in %f(%l):%m misses the column
    -- form entirely, which would leave C# errors unparsed.
    "%f(%l\\,%c): %trror %m",
    "%f(%l\\,%c): %tarning %m",
    "%f(%l): %trror %m",
    "%f(%l): %tarning %m",
    -- Driver/linker failures carry no file:line, but still belong in the list —
    -- otherwise a link error shows up as an empty quickfix. %+E keeps the whole
    -- matched line as the message, and the %+C rule below folds the indented
    -- symbol list into it; finish() flattens the result to one line.
    "%Wld: warning: %m",
    "%+EUndefined symbols%.%#",
    "%+Eld: %.%#",
    "%+Eclang++: %trror: %.%#",
    "%+Eclang: %trror: %.%#",
    "%+Eg++: %trror: %.%#",
    "%+Egcc: %trror: %.%#",
    -- CMake states the location on the first line and the message below it
    "%ECMake Error at %f:%l (%.%#):",
    "%WCMake Warning at %f:%l (%.%#):",
    "%ECMake Error: %m",
    "%+C  %.%#",
    "%Z",
    vim.o.errorformat,
  }, ",")
end

----------------------------------------------------------------- statusline --

--- Feed to lualine. Empty until the first build of the session.
function M.statusline()
  if state.status == "running" then
    return string.format("%s %s %.0fs", SPINNER[state.frame], state.label, state.elapsed)
  elseif state.status == "ok" then
    if state.warnings > 0 then
      return string.format("✓ %s %.1fs %dW", state.label, state.elapsed, state.warnings)
    end
    return string.format("✓ %s %.1fs", state.label, state.elapsed)
  elseif state.status == "failed" then
    if state.errors == 0 and state.warnings == 0 then
      return string.format("✗ %s", state.label)
    end
    return string.format("✗ %d E %d W", state.errors, state.warnings)
  elseif state.status == "cancelled" then
    return string.format("■ %s", state.label)
  end
  return ""
end

function M.statusline_hl()
  if state.status == "failed" then
    return "DiagnosticError"
  elseif state.status == "ok" then
    return "DiagnosticOk"
  elseif state.status == "running" then
    return "DiagnosticWarn"
  end
  return nil
end

local function start_ticking()
  state.frame = 1
  state.start = uv.hrtime()
  state.elapsed = 0
  if state.timer then
    state.timer:stop()
    state.timer:close()
  end
  state.timer = uv.new_timer()
  state.timer:start(
    100,
    100,
    vim.schedule_wrap(function()
      state.frame = state.frame % #SPINNER + 1
      state.elapsed = (uv.hrtime() - state.start) / 1e9
      vim.cmd("redrawstatus")
    end)
  )
end

local function stop_ticking()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  state.elapsed = (uv.hrtime() - state.start) / 1e9
  vim.cmd("redrawstatus")
end

------------------------------------------------------------ project lookup --

local function search_dir()
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= "" and uv.fs_stat(name) then
    return vim.fs.dirname(name)
  end
  return vim.fn.getcwd()
end

local function find_up(names)
  return vim.fs.find(names, { path = search_dir(), upward = true, type = "file" })[1]
end

local function is_dir(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == "directory"
end

--- A CMakeCache.txt alone does NOT mean the directory is usable: cmake writes the
--- cache before it can fail (an unresolved find_package, say), leaving a dir that
--- looks configured but has no generated build system. Requiring the generator's
--- output too means a failed configure is retried instead of building nothing.
local function is_configured(dir)
  if not dir or not uv.fs_stat(dir .. "/CMakeCache.txt") then
    return false
  end
  for _, generated in ipairs({ "Makefile", "build.ninja", "CMakeFiles/rules.ninja" }) do
    if uv.fs_stat(dir .. "/" .. generated) then
      return true
    end
  end
  -- IDE generators (Xcode, Visual Studio) emit a project file instead
  return #vim.fn.glob(dir .. "/*.xcodeproj", false, true) > 0 or #vim.fn.glob(dir .. "/*.sln", false, true) > 0
end

--- Native tool args that make the build report every failure instead of the
--- first one. Both make and ninja stop scheduling new jobs the moment a
--- compile fails, so with -Werror a quickfix list would hold only whichever
--- diagnostics happened to be in flight — build the whole tree, then stop.
--- Generator-specific and passed after `--`; unknown generators (Xcode, VS)
--- get nothing rather than a flag their driver would reject.
local function keep_going_args(dir)
  if not dir then
    return {}
  end
  if uv.fs_stat(dir .. "/build.ninja") then
    return { "--", "-k", "0" } -- ninja: 0 means "never stop early"
  end
  if uv.fs_stat(dir .. "/Makefile") then
    return { "--", "-k" }
  end
  return {}
end

local function cmake_build_dir(root)
  local names = vim.g.build_dirs or BUILD_DIRS
  local existing
  for _, name in ipairs(names) do
    local dir = root .. "/" .. name
    if is_configured(dir) then
      return dir, true
    end
    if not existing and is_dir(dir) then
      existing = dir
    end
  end
  return existing or (root .. "/" .. names[1]), false
end

local function jobs()
  if vim.g.build_jobs then
    return vim.g.build_jobs
  end
  local ok, cpus = pcall(uv.cpu_info)
  return (ok and cpus and #cpus > 0) and #cpus or 4
end

--------------------------------------------------------------- cmake presets --

-- A project with CMakePresets.json must be driven through its presets: the
-- preset carries the toolchain file (vcpkg, for instance) and the real binary
-- dir, which is typically build/<presetName> rather than build/. Configuring
-- such a project by hand leaves a toolchain-less cache in build/ that then
-- looks configured to a naive probe.

local PRESET_STATE = vim.fn.stdpath("cache") .. "/nvim_build_preset.json"

local preset_cache = {} -- root -> parsed presets, invalidated on file mtime

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

--- Preset names cmake itself reports for `kind`. Delegating to cmake means the
--- `condition` fields (host OS gates) are evaluated by cmake, not reimplemented.
local function list_presets(root, kind)
  local cmd = { "cmake", "--list-presets" }
  if kind then
    cmd[2] = "--list-presets=" .. kind
  end
  local res = vim.system(cmd, { cwd = root, text = true }):wait()
  local names = {}
  if res.code == 0 then
    for line in (res.stdout or ""):gmatch("[^\n]+") do
      local name = line:match('^%s*"([^"]+)"')
      if name then
        names[#names + 1] = name
      end
    end
  end
  return names
end

--- binaryDir is inherited, and expands ${sourceDir} / ${presetName} — the latter
--- against the preset being built, not the ancestor that declared the field.
local function preset_binary_dir(defs, name, root)
  local seen, cur = {}, name
  while cur and not seen[cur] do
    seen[cur] = true
    local def = defs[cur]
    if not def then
      return nil
    end
    if def.binaryDir then
      local dir = def.binaryDir:gsub("%${sourceDir}", root):gsub("%${presetName}", name)
      return dir
    end
    local inherits = def.inherits
    cur = type(inherits) == "table" and inherits[1] or inherits
  end
  return nil
end

--- nil when the project has no presets, or none usable on this host.
local function load_presets(root)
  local files = { root .. "/CMakePresets.json", root .. "/CMakeUserPresets.json" }
  local mtime = 0
  for _, path in ipairs(files) do
    local st = uv.fs_stat(path)
    if st then
      mtime = math.max(mtime, st.mtime.sec)
    end
  end
  if mtime == 0 then
    return nil
  end

  local cached = preset_cache[root]
  if cached and cached.mtime == mtime then
    return cached.presets
  end

  local configure = list_presets(root, nil)
  if #configure == 0 then
    preset_cache[root] = { mtime = mtime, presets = nil }
    return nil
  end

  local defs = {}
  for _, path in ipairs(files) do
    local data = read_json(path)
    for _, def in ipairs(data and data.configurePresets or {}) do
      if def.name then
        defs[def.name] = def
      end
    end
  end

  local buildable = {}
  for _, name in ipairs(list_presets(root, "build")) do
    buildable[name] = true
  end

  local binary = {}
  for _, name in ipairs(configure) do
    binary[name] = preset_binary_dir(defs, name, root)
  end

  local presets = { configure = configure, buildable = buildable, binary = binary }
  preset_cache[root] = { mtime = mtime, presets = presets }
  return presets
end

local function saved_presets()
  return read_json(PRESET_STATE) or {}
end

--- Which preset to use: an explicit override, else the last one chosen for this
--- project, else the first cmake reports as valid here.
local function pick_preset(root, presets)
  if vim.g.build_preset then
    return vim.g.build_preset
  end
  local saved = saved_presets()[root]
  if saved and vim.tbl_contains(presets.configure, saved) then
    return saved
  end
  return presets.configure[1]
end

function M.choose_preset()
  local cmakelists = find_up("CMakeLists.txt")
  local root = cmakelists and vim.fs.dirname(cmakelists)
  local presets = root and load_presets(root)
  if not presets then
    vim.notify("no usable CMake presets for this project", vim.log.levels.WARN)
    return
  end

  vim.ui.select(presets.configure, { prompt = "CMake preset:" }, function(choice)
    if not choice then
      return
    end
    local saved = saved_presets()
    saved[root] = choice
    vim.fn.writefile({ vim.json.encode(saved) }, PRESET_STATE)
    vim.g.build_preset = nil -- the saved choice would otherwise be shadowed
    vim.notify("build preset: " .. choice)
  end)
end

--- The CMake source root for the current buffer, or nil.
function M.project_root()
  local cmakelists = find_up("CMakeLists.txt")
  return cmakelists and vim.fs.dirname(cmakelists)
end

--- Where this project's build artifacts land, honouring the selected preset.
--- Exposed for user/run.lua, which locates built executables under it — the
--- preset resolution must not be duplicated, or the two would disagree about
--- which directory (build/ vs build/<preset>/) is current.
---
--- `root` may be passed explicitly: callers running from a floating window cannot
--- rely on the current buffer to locate the project.
function M.binary_dir(root)
  root = root or M.project_root()
  if not root then
    return nil
  end
  local presets = load_presets(root)
  if presets then
    return presets.binary[pick_preset(root, presets)], root
  end
  local dir = cmake_build_dir(root)
  return dir, root
end

--- Resolve the steps needed to build whatever project the current buffer is in.
--- Returns a step list and a short label, or nil plus a reason.
---
--- `vim.g.build_command` (a string or argv list) overrides detection entirely,
--- with `vim.g.build_cwd` for its working directory.
local function resolve(opts)
  opts = opts or {}

  if vim.g.build_command then
    local cmd = vim.g.build_command
    if type(cmd) == "string" then
      cmd = { vim.o.shell, "-c", cmd }
    end
    return { { cmd = cmd, cwd = vim.g.build_cwd or vim.fn.getcwd() } }, "build"
  end

  local cmakelists = find_up("CMakeLists.txt")
  if cmakelists then
    local root = vim.fs.dirname(cmakelists)
    local steps = {}

    -- Presets win when present: they hold the toolchain file and the real binary
    -- dir. Probing for build/CMakeCache.txt here would happily find a stale
    -- toolchain-less cache and build the project wrong.
    local presets = load_presets(root)
    if presets then
      local preset = pick_preset(root, presets)
      local dir = presets.binary[preset]

      if (dir and not is_configured(dir)) or opts.configure then
        steps[#steps + 1] = { cmd = { "cmake", "--preset", preset }, cwd = root }
      end

      if not opts.configure_only then
        local cmd
        if presets.buildable[preset] then
          cmd = { "cmake", "--build", "--preset", preset }
        else
          -- configure preset with no matching build preset: drive the dir itself
          cmd = { "cmake", "--build", dir or (root .. "/build") }
        end
        vim.list_extend(cmd, { "--parallel", tostring(jobs()) })
        if opts.clean then
          table.insert(cmd, "--clean-first")
        end
        steps[#steps + 1] = { cmd = cmd, cwd = root, keep_going = dir or (root .. "/build") }
      end

      return steps, vim.fs.basename(root), preset
    end

    local dir, configured = cmake_build_dir(root)

    -- Configure when there is no cache yet, or on an explicit request. Export
    -- compile_commands.json while we are here: clangd picks it up from build/.
    if not configured or opts.configure then
      steps[#steps + 1] = {
        cmd = { "cmake", "-S", root, "-B", dir, "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON" },
        cwd = root,
      }
    end

    if not opts.configure_only then
      local cmd = { "cmake", "--build", dir, "--parallel", tostring(jobs()) }
      if opts.clean then
        table.insert(cmd, "--clean-first")
      end
      steps[#steps + 1] = { cmd = cmd, cwd = root, keep_going = dir }
    end

    return steps, vim.fs.basename(root)
  end

  local makefile = find_up({ "Makefile", "makefile", "GNUmakefile" })
  if makefile then
    local root = vim.fs.dirname(makefile)
    -- -k here directly: make is the build tool, so there is no `--` to cross.
    local cmd = { "make", "-k", "-j", tostring(jobs()) }
    if opts.clean then
      cmd = { "make", "-k", "clean", "all" }
    end
    if opts.configure or opts.configure_only then
      return nil, "no CMake project here — nothing to configure"
    end
    return { { cmd = cmd, cwd = root } }, vim.fs.basename(root)
  end

  return nil, "no CMakeLists.txt or Makefile above " .. vim.fn.fnamemodify(search_dir(), ":~")
end

------------------------------------------------------------------- running --

--- A per-stream sink that reassembles lines: vim.system hands over arbitrary
--- chunks, and a diagnostic split across two of them would parse as two bogus
--- quickfix entries. stdout and stderr each need their own partial buffer.
local function line_sink()
  local partial = ""
  return function(_, chunk)
    if not chunk then
      if partial ~= "" then
        state.output[#state.output + 1] = partial
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
      state.output[#state.output + 1] = (partial:sub(from, nl - 1):gsub("\r$", ""))
      from = nl + 1
    end
    partial = partial:sub(from)
  end
end

--- Parse the accumulated output into quickfix and surface the result.
local function finish(code)
  stop_ticking()

  local title = "build: " .. state.label
  if state.preset then
    title = title .. " (" .. state.preset .. ")"
  end

  vim.fn.setqflist({}, " ", { title = title, lines = state.output, efm = errorformat() })

  -- Lines matching no pattern still land in the list as valid=0 entries: compile
  -- progress, caret context, make's "*** Error 1" trailers. Drop them so the
  -- list holds diagnostics only — the raw output stays available via M.output().
  local items = vim.tbl_filter(function(item)
    return item.valid == 1
  end, vim.fn.getqflist())

  -- Multi-line messages (folded linker/CMake errors) arrive with embedded
  -- newlines, which the quickfix window and Trouble both render badly.
  for _, item in ipairs(items) do
    item.text = item.text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  end

  vim.fn.setqflist({}, "r", { title = title, items = items })

  state.errors, state.warnings = 0, 0
  for _, item in ipairs(items) do
    local t = item.type:upper()
    if t == "E" then
      state.errors = state.errors + 1
    elseif t == "W" then
      state.warnings = state.warnings + 1
    end
  end

  if code == 0 then
    state.status = "ok"
    -- A clean build should not leave the previous run's list on screen.
    pcall(vim.cmd, "Trouble qflist close")
    local msg = string.format("build ok (%.1fs)", state.elapsed)
    if state.warnings > 0 then
      msg = msg .. string.format(" — %d warning%s", state.warnings, state.warnings == 1 and "" or "s")
    end
    vim.notify(msg, vim.log.levels.INFO)
  else
    state.status = "failed"
    if #items > 0 then
      pcall(vim.cmd, "Trouble qflist open focus=false")
      vim.notify(
        string.format("build failed — %d error(s), %d warning(s)", state.errors, state.warnings),
        vim.log.levels.ERROR
      )
    else
      -- Nothing matched: a link error, a missing tool, a CMake blowup.
      vim.notify("build failed (exit " .. code .. ") — <leader>bo for output", vim.log.levels.ERROR)
    end
  end

  vim.cmd("redrawstatus")
end

local run_steps

--- Run one step; on success continue with the rest of the queue.
local function run_step(step)
  local opts = { cwd = step.cwd, stdout = line_sink(), stderr = line_sink(), text = true }

  -- Resolved here rather than in resolve(): on a first build the generator's
  -- files do not exist yet — the configure step ahead of us in the queue is
  -- what creates them. Copy, because `state.last` reuses these step tables and
  -- appending in place would stack the flags on every re-run.
  local cmd = step.cmd
  if step.keep_going then
    cmd = vim.list_extend(vim.list_slice(cmd), keep_going_args(step.keep_going))
  end

  state.job = vim.system(cmd, opts, function(res)
    vim.schedule(function()
      state.job = nil

      if state.cancelled then
        state.cancelled = false
        return
      end

      if state.pending then
        -- A new build was requested while this one was being killed.
        local queued = state.pending
        state.pending = nil
        run_steps(queued.steps, queued.label, queued.preset)
        return
      end

      if res.code ~= 0 or #state.queue == 0 then
        finish(res.code)
        return
      end

      run_step(table.remove(state.queue, 1))
    end)
  end)
end

run_steps = function(steps, label, preset)
  state.queue = vim.list_slice(steps, 2)
  state.output = {}
  state.label = label
  state.preset = preset
  state.status = "running"
  state.cancelled = false
  state.errors, state.warnings = 0, 0
  state.last = { steps = steps, label = label, preset = preset }
  start_ticking()
  run_step(steps[1])
end

--- Kick off a build. Options: `clean`, `configure`, `configure_only`.
--- A build already in flight is killed and replaced — saving and rebuilding in a
--- tight loop should not require cancelling by hand.
function M.run(opts)
  local steps, label, preset = resolve(opts)
  if not steps then
    vim.notify(label, vim.log.levels.WARN)
    return
  end

  if state.job then
    state.pending = { steps = steps, label = label, preset = preset }
    state.job:kill(15)
    return
  end

  run_steps(steps, label, preset)
end

--- Re-run the previous build verbatim, ignoring which buffer is current.
function M.again()
  if not state.last then
    M.run()
    return
  end
  if state.job then
    state.pending = state.last
    state.job:kill(15)
    return
  end
  run_steps(state.last.steps, state.last.label, state.last.preset)
end

function M.cancel()
  if not state.job then
    vim.notify("no build running", vim.log.levels.INFO)
    return
  end
  state.pending = nil
  state.queue = {}
  state.cancelled = true -- stops the exit handler from reporting this as a failure
  state.job:kill(15)
  state.status = "cancelled"
  stop_ticking()
  vim.notify("build cancelled", vim.log.levels.WARN)
end

--- Show the raw output of the last run in a scratch split. This is the escape
--- hatch for failures errorformat cannot express.
function M.output()
  if #state.output == 0 then
    vim.notify("no build output yet", vim.log.levels.INFO)
    return
  end

  local buf
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match(OUTPUT_BUF_NAME .. "$") then
      buf = b
      break
    end
  end
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, OUTPUT_BUF_NAME)
    vim.bo[buf].filetype = "log"
    vim.bo[buf].buftype = "nofile"
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, state.output)
  vim.bo[buf].modifiable = false

  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_win_set_height(0, math.floor(vim.o.lines * 0.4))
  end
  vim.cmd("normal! G")
end

------------------------------------------------------------------- wiring --

function M.setup()
  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { desc = desc })
  end

  map("<leader>bb", function()
    M.run()
  end, "Build")
  map("<leader>bl", M.again, "Re-run last build")
  map("<leader>bB", function()
    M.run({ clean = true })
  end, "Clean rebuild")
  map("<leader>bc", function()
    M.run({ configure = true })
  end, "CMake configure + build")
  map("<leader>bC", function()
    M.run({ configure = true, configure_only = true })
  end, "CMake configure only")
  map("<leader>bo", M.output, "Build output")
  map("<leader>bx", M.cancel, "Cancel build")
  map("<leader>bp", M.choose_preset, "Pick CMake preset")

  vim.api.nvim_create_user_command("Build", function(cmd)
    M.run({ clean = cmd.bang })
  end, { bang = true, desc = "Build the current project (! to clean first)" })
end

return M
