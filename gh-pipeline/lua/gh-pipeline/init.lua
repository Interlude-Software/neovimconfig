-- gh-pipeline: a PR-blocker board for GitHub.
-- Floating window listing open PRs and, per PR, every REQUIRED status check with
-- its state -- including "expected, never reported" required checks that silently
-- block a merge (invisible to both `gh run list` and `gh pr checks`).
-- Shells out to the `gh` CLI (reuses gh auth).

local M = {}

local config = {
  refresh_ms = 8000, -- auto-refresh cadence while the float is open
  limit = 50, -- max open PRs to scan
  author = "@me", -- whose PRs to show: "@me", a username, or false for all
  show_passing = false, -- list every passing check, or collapse them to a summary
  width = 0.7, -- float size as a fraction of the editor
  height = 0.7,
}

local ns = vim.api.nvim_create_namespace("gh_pipeline")

-- Live UI state for the single floating panel.
local state = {
  buf = nil,
  win = nil,
  timer = nil,
  repo = nil, -- owner/repo, cached
  line_actions = {}, -- 0-indexed buffer line -> { url = ... }
  loading = false,
}

-- ---------------------------------------------------------------------------
-- gh helpers
-- ---------------------------------------------------------------------------

-- Run `gh` from the current buffer's directory so it resolves the right repo.
local function repo_dir()
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= "" and vim.fn.filereadable(name) == 1 then
    return vim.fs.dirname(name)
  end
  return vim.fn.getcwd()
end

-- Async `gh`. cb(ok, json_or_nil, err). If decode is false, returns raw stdout.
local function gh(args, opts, cb)
  opts = opts or {}
  vim.system(
    vim.list_extend({ "gh" }, args),
    { cwd = state.cwd or repo_dir(), text = true },
    function(res)
      vim.schedule(function()
        if res.code ~= 0 then
          cb(false, nil, (res.stderr ~= "" and res.stderr or "gh exited " .. res.code))
          return
        end
        if opts.raw then
          cb(true, vim.trim(res.stdout), nil)
          return
        end
        local ok, data = pcall(vim.json.decode, res.stdout)
        if not ok then
          cb(false, nil, "failed to parse gh output")
          return
        end
        cb(true, data, nil)
      end)
    end
  )
end

-- ---------------------------------------------------------------------------
-- check classification
-- ---------------------------------------------------------------------------

local KIND = {
  pass = { icon = "✓", hl = "GhPipelinePass" },
  fail = { icon = "✗", hl = "GhPipelineFail" },
  running = { icon = "◐", hl = "GhPipelineRunning" },
  queued = { icon = "●", hl = "GhPipelineQueued" },
  expected = { icon = "⚠", hl = "GhPipelineExpected" },
  unknown = { icon = "•", hl = "Comment" },
}

local FAIL_CONCLUSIONS = {
  FAILURE = true,
  TIMED_OUT = true,
  CANCELLED = true,
  STARTUP_FAILURE = true,
  ACTION_REQUIRED = true,
  STALE = true,
}

-- Normalise a rollup entry (CheckRun or StatusContext) into { name, kind, detail, url }.
local function classify(entry)
  if entry.__typename == "StatusContext" then
    local s = entry.state
    local kind = "unknown"
    if s == "SUCCESS" then
      kind = "pass"
    elseif s == "PENDING" or s == "EXPECTED" then
      kind = "running"
    elseif s == "ERROR" or s == "FAILURE" then
      kind = "fail"
    end
    return { name = entry.context, kind = kind, detail = nil, url = entry.targetUrl }
  end

  -- CheckRun
  local status, concl = entry.status, entry.conclusion
  local kind
  if status == "QUEUED" or status == "REQUESTED" or status == "WAITING" or status == "PENDING" then
    kind = "queued"
  elseif status == "IN_PROGRESS" then
    kind = "running"
  elseif status == "COMPLETED" then
    if concl == "SUCCESS" or concl == "NEUTRAL" or concl == "SKIPPED" then
      kind = "pass"
    elseif FAIL_CONCLUSIONS[concl] then
      kind = "fail"
    else
      kind = "unknown"
    end
  else
    kind = "unknown"
  end
  return { name = entry.name, kind = kind, detail = nil, url = entry.detailsUrl }
end

-- ---------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------

-- Order PRs: blocked/problem states first, then by number desc.
local function merge_rank(s)
  if s == "BLOCKED" or s == "DIRTY" then
    return 0
  elseif s == "UNSTABLE" or s == "BEHIND" then
    return 1
  end
  return 2
end

-- Highlight for a PR header line based on its merge state.
local function merge_hl(s)
  if s == "CLEAN" or s == "HAS_HOOKS" then
    return "GhPipelineClean"
  elseif s == "BLOCKED" or s == "DIRTY" or s == "UNSTABLE" or s == "BEHIND" then
    return "GhPipelineBlocked"
  end
  return "GhPipelinePR"
end

local function add(lines, hls, text, hl, action)
  table.insert(lines, text)
  local line = #lines - 1
  if hl then
    hls[#hls + 1] = { line = line, hl = hl }
  end
  if action then
    state.line_actions[line] = action
  end
end

-- prs: array from gh pr list. required: { [base] = {contexts}|false (unavailable) }.
local function build(prs, required, err)
  local lines, hls = {}, {}
  state.line_actions = {}

  local repo = state.repo or vim.fs.basename(repo_dir())
  local scope = config.author == "@me" and " (yours)"
    or (config.author and (" (@" .. config.author:gsub("^@", "") .. ")"))
    or ""
  local count = prs and ("  ·  " .. #prs .. " open") or ""
  local status = state.loading and "   ⟳ refreshing…" or ""
  add(lines, hls, "  PRs blocking merge — " .. repo .. scope .. count .. status, "Title")
  add(lines, hls, "", nil)

  if err then
    add(lines, hls, "  error: " .. err, "GhPipelineFail")
    return lines, hls
  end

  if not prs or #prs == 0 then
    add(lines, hls, "  No open PRs ✓", "GhPipelinePass")
    add(lines, hls, "", nil)
    add(lines, hls, "  <CR> open  r refresh  q quit", "Comment")
    return lines, hls
  end

  -- Adaptive title width based on the current window.
  local win_w = (state.win and vim.api.nvim_win_is_valid(state.win))
      and vim.api.nvim_win_get_width(state.win)
    or math.floor(vim.o.columns * config.width)
  local title_max = math.max(20, win_w - 11)

  table.sort(prs, function(a, b)
    local ra, rb = merge_rank(a.mergeStateStatus), merge_rank(b.mergeStateStatus)
    if ra ~= rb then
      return ra < rb
    end
    return a.number > b.number
  end)

  -- Render one check row.
  local function check_row(kind, name, suffix, url)
    local k = KIND[kind]
    local text = string.format("     %s %s%s", k.icon, name, suffix or "")
    add(lines, hls, text, k.hl, url and { url = url })
  end

  for _, pr in ipairs(prs) do
    -- PR header, colored by merge state.
    local head = string.format(
      "  #%-4d %s → %s   [%s]",
      pr.number,
      pr.headRefName or "?",
      pr.baseRefName or "?",
      pr.mergeStateStatus or "?"
    )
    add(lines, hls, head, merge_hl(pr.mergeStateStatus), { url = pr.url })
    if pr.title and pr.title ~= "" then
      local title = pr.title:sub(1, title_max)
      if #pr.title > title_max then
        title = title .. "…"
      end
      add(lines, hls, "       " .. title, "Comment", { url = pr.url })
    end

    -- Map reported checks by name.
    local reported = {}
    for _, entry in ipairs(pr.statusCheckRollup or {}) do
      local c = classify(entry)
      if c.name then
        reported[c.name] = c
      end
    end

    local req = required[pr.baseRefName]
    if req == false then
      add(lines, hls, "     (required-check list unavailable — needs admin)", "Comment")
      for name, c in pairs(reported) do
        check_row(c.kind, name, nil, c.url)
      end
    elseif req and #req > 0 then
      -- Walk required contexts: surface problems, collapse passes.
      local passed = 0
      for _, name in ipairs(req) do
        local c = reported[name]
        if not c then
          check_row("expected", name, " — expected, never reported", nil)
        elseif c.kind == "pass" then
          passed = passed + 1
          if config.show_passing then
            check_row("pass", name, nil, c.url)
          end
        else
          check_row(c.kind, name, nil, c.url)
        end
      end
      if not config.show_passing and passed > 0 then
        local all = passed == #req
        local text = all and string.format("     ✓ all %d required checks passed", #req)
          or string.format("     ✓ %d/%d required passed", passed, #req)
        add(lines, hls, text, all and "GhPipelineClean" or "Comment")
      end
    else
      -- No branch protection on the base; show reported checks plainly.
      for name, c in pairs(reported) do
        check_row(c.kind, name, nil, c.url)
      end
      if not next(reported) then
        add(lines, hls, "     (no checks reported)", "Comment")
      end
    end

    add(lines, hls, "", nil)
  end

  add(lines, hls, "  <CR> open  r refresh  q quit", "Comment")
  return lines, hls
end

-- ---------------------------------------------------------------------------
-- window plumbing
-- ---------------------------------------------------------------------------

local function is_open()
  return state.win and vim.api.nvim_win_is_valid(state.win)
end

local function apply(prs, required, err)
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end
  local lines, hls = build(prs, required, err)

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(state.buf, ns, h.hl, h.line, 0, -1)
  end
end

-- Orchestrate the fetches: repo name -> PRs -> required contexts per base.
local function refresh()
  if not is_open() then
    return
  end
  state.loading = true
  state.cwd = repo_dir()

  local function with_repo(next)
    if state.repo then
      return next()
    end
    gh({ "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner" }, { raw = true }, function(ok, name)
      if ok and name ~= "" then
        state.repo = name
      end
      next()
    end)
  end

  with_repo(function()
    local args = {
      "pr",
      "list",
      "--state",
      "open",
      "--limit",
      tostring(config.limit),
      "--json",
      "number,title,headRefName,baseRefName,mergeStateStatus,url,statusCheckRollup",
    }
    if config.author then
      vim.list_extend(args, { "--author", config.author })
    end
    gh(args, {}, function(ok, prs, err)
      if not ok then
        state.loading = false
        if is_open() then
          apply(nil, {}, err)
        end
        return
      end

      -- Collect distinct base branches.
      local bases, seen = {}, {}
      for _, pr in ipairs(prs) do
        local b = pr.baseRefName
        if b and not seen[b] then
          seen[b] = true
          bases[#bases + 1] = b
        end
      end

      local required = {}
      local pending = #bases

      local function finish()
        state.loading = false
        if is_open() then
          apply(prs, required, nil)
        end
      end

      if pending == 0 then
        return finish()
      end

      for _, base in ipairs(bases) do
        gh({
          "api",
          string.format("repos/{owner}/{repo}/branches/%s/protection/required_status_checks", base),
          "-q",
          ".contexts",
        }, {}, function(ok2, contexts)
          required[base] = (ok2 and contexts) or false
          pending = pending - 1
          if pending == 0 then
            finish()
          end
        end)
      end
    end)
  end)
end

local function action_under_cursor()
  local row = vim.api.nvim_win_get_cursor(state.win)[1] - 1
  return state.line_actions[row]
end

local function close()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  if is_open() then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
  state.buf = nil
end

local function set_keymaps(buf)
  local map = function(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("q", close)
  map("<Esc>", close)
  map("r", refresh)
  map("<CR>", function()
    local a = action_under_cursor()
    if a and a.url then
      vim.ui.open(a.url)
    end
  end)
end

local function define_highlights()
  local defs = {
    GhPipelinePass = "DiagnosticOk",
    GhPipelineFail = "DiagnosticError",
    GhPipelineRunning = "DiagnosticInfo",
    GhPipelineQueued = "DiagnosticWarn",
    GhPipelineExpected = "DiagnosticWarn",
    GhPipelinePR = "Title",
    GhPipelineBlocked = "DiagnosticWarn",
    GhPipelineClean = "DiagnosticOk",
  }
  for name, link in pairs(defs) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

function M.open()
  if vim.fn.executable("gh") == 0 then
    vim.notify("gh-pipeline: `gh` CLI not found on PATH", vim.log.levels.ERROR)
    return
  end
  if is_open() then
    vim.api.nvim_set_current_win(state.win)
    return
  end

  define_highlights()
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].filetype = "gh-pipeline"

  local w = math.floor(vim.o.columns * config.width)
  local h = math.floor(vim.o.lines * config.height)
  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = w,
    height = h,
    row = math.floor((vim.o.lines - h) / 2),
    col = math.floor((vim.o.columns - w) / 2),
    style = "minimal",
    border = "rounded",
    title = " pipeline ",
    title_pos = "center",
  })
  vim.wo[state.win].cursorline = true

  set_keymaps(state.buf)
  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = state.buf,
    once = true,
    callback = close,
  })

  apply({}, {}, nil) -- initial frame
  refresh()

  state.timer = vim.uv.new_timer()
  state.timer:start(
    config.refresh_ms,
    config.refresh_ms,
    vim.schedule_wrap(function()
      refresh()
    end)
  )
end

function M.setup(opts)
  config = vim.tbl_extend("force", config, opts or {})
  vim.api.nvim_create_user_command("GhPipeline", function()
    M.open()
  end, { desc = "GitHub: PRs blocking merge + required-check state" })
end

return M
