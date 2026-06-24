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
  queue_runs = 25, -- max recent runs to fetch jobs for in the queue view
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
  view = "board", -- "board" (PR blockers) or "queue" (CI jobs in processing order)
  spin_timer = nil, -- drives the loading spinner animation
  spin_frame = 1,
}

-- Braille spinner frames, advanced on a short timer while a fetch is in flight.
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- Header decoration shown while loading: animated spinner, else nothing.
local function spinner_text()
  if not state.loading then
    return ""
  end
  return "   " .. SPINNER[state.spin_frame] .. " refreshing…"
end

-- Active run/job statuses (work that is queued or executing), in the order the
-- GitHub Actions API may report them.
local ACTIVE_STATUS = {
  queued = true,
  in_progress = true,
  waiting = true,
  requested = true,
  pending = true,
}

-- A completed job's conclusion -> KIND bucket. Mirrors classify()/FAIL list,
-- but cancellations get their own bucket so they read distinctly in the queue.
local CONCLUSION_KIND = {
  success = "pass",
  neutral = "pass",
  skipped = "pass",
  failure = "fail",
  timed_out = "fail",
  startup_failure = "fail",
  action_required = "fail",
  stale = "fail",
  cancelled = "cancelled",
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
          -- Flatten gh's multi-line stderr to a single line; buffer lines
          -- can't contain newlines.
          local msg = res.stderr ~= "" and res.stderr or ("gh exited " .. res.code)
          msg = vim.trim(msg:gsub("%s*\n%s*", " "))
          cb(false, nil, msg)
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

-- Extract the Actions run id from a run/job URL, e.g.
-- https://github.com/owner/repo/actions/runs/123/job/456 -> "123".
local function run_id_from_url(url)
  if type(url) ~= "string" then
    return nil
  end
  return url:match("/actions/runs/(%d+)")
end

-- ---------------------------------------------------------------------------
-- check classification
-- ---------------------------------------------------------------------------

local KIND = {
  pass = { icon = "✓", hl = "GhPipelinePass" },
  fail = { icon = "✗", hl = "GhPipelineFail" },
  running = { icon = "◐", hl = "GhPipelineRunning" },
  queued = { icon = "●", hl = "GhPipelineQueued" },
  cancelled = { icon = "⊘", hl = "GhPipelineCancelled" },
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
  state.header_base = "  PRs blocking merge — " .. repo .. scope .. count
  add(lines, hls, state.header_base .. spinner_text(), "Title")
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

  -- Render one check row. The check's detailsUrl identifies its Actions run,
  -- so carry the run id along for `R`/`F` reruns.
  local function check_row(kind, name, suffix, url)
    local k = KIND[kind]
    local text = string.format("     %s %s%s", k.icon, name, suffix or "")
    local action = url and { url = url, run_id = run_id_from_url(url) } or nil
    add(lines, hls, text, k.hl, action)
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

  add(lines, hls, "  <CR> open  R rerun  F rerun-failed  r refresh  Tab queue  q quit", "Comment")
  return lines, hls
end

-- jobs: array of { name, branch, kind, label, url, created, active } already
-- sorted into processing order (see refresh_queue).
local function build_queue(jobs, err)
  local lines, hls = {}, {}
  state.line_actions = {}

  local repo = state.repo or vim.fs.basename(repo_dir())
  local active_n = 0
  for _, j in ipairs(jobs or {}) do
    if j.active then
      active_n = active_n + 1
    end
  end
  local count = jobs and string.format("  ·  %d recent (%d active)", #jobs, active_n) or ""
  state.header_base = "  CI queue (processing order) — " .. repo .. count
  add(lines, hls, state.header_base .. spinner_text(), "Title")
  add(lines, hls, "", nil)

  if err then
    add(lines, hls, "  error: " .. err, "GhPipelineFail")
    return lines, hls
  end

  if not jobs or #jobs == 0 then
    add(lines, hls, "  No recent jobs ✓", "GhPipelinePass")
    add(lines, hls, "", nil)
    add(lines, hls, "  <CR> open  r refresh  Tab board  q quit", "Comment")
    return lines, hls
  end

  -- Adaptive column widths based on the current window.
  local win_w = (state.win and vim.api.nvim_win_is_valid(state.win))
      and vim.api.nvim_win_get_width(state.win)
    or math.floor(vim.o.columns * config.width)
  -- Layout: "  NN  <icon> job  branch  status"
  -- Reserve room for index/icon/status, split the rest between job and branch.
  local rest = math.max(30, win_w - 24)
  local job_max = math.max(16, math.floor(rest * 0.6))
  local branch_max = math.max(10, rest - job_max)

  local function trunc(s, n)
    s = s or "?"
    if #s > n then
      return s:sub(1, n - 1) .. "…"
    end
    return s
  end

  -- Column header.
  add(
    lines,
    hls,
    string.format("   #   %-" .. job_max .. "s  %-" .. branch_max .. "s  %s", "job", "PR / branch", "status"),
    "Comment"
  )

  for i, job in ipairs(jobs) do
    local k = KIND[job.kind] or KIND.unknown
    local text = string.format(
      "  %2d %s %-" .. job_max .. "s  %-" .. branch_max .. "s  %s",
      i,
      k.icon,
      trunc(job.name, job_max),
      trunc(job.branch, branch_max),
      job.label
    )
    add(lines, hls, text, k.hl, (job.url or job.run_id) and { url = job.url, run_id = job.run_id })
  end

  add(lines, hls, "", nil)
  add(lines, hls, "  <CR> open  R rerun  F rerun-failed  r refresh  Tab board  q quit", "Comment")
  return lines, hls
end

-- ---------------------------------------------------------------------------
-- window plumbing
-- ---------------------------------------------------------------------------

local function is_open()
  return state.win and vim.api.nvim_win_is_valid(state.win)
end

-- Render whichever view is active. For the board pass (prs, required, err);
-- for the queue pass (jobs, nil, err) -- the second arg is ignored there.
local function apply(data, required, err)
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end
  local lines, hls
  if state.view == "queue" then
    lines, hls = build_queue(data, err)
  else
    lines, hls = build(data, required, err)
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(state.buf, ns, h.hl, h.line, 0, -1)
  end
end

-- Repaint only the header line (line 0) with the current spinner frame. Cheap
-- enough to run on the spinner's fast timer without touching the rest/cursor.
local function paint_header()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf) and state.header_base) then
    return
  end
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, 1, false, { state.header_base .. spinner_text() })
  vim.bo[state.buf].modifiable = false
  vim.api.nvim_buf_add_highlight(state.buf, ns, "Title", 0, 0, -1)
end

-- Start the spinner animation (no-op if already running).
local function spinner_start()
  if state.spin_timer then
    return
  end
  state.spin_timer = vim.uv.new_timer()
  state.spin_timer:start(
    0,
    100,
    vim.schedule_wrap(function()
      if not (state.loading and state.win and vim.api.nvim_win_is_valid(state.win)) then
        return
      end
      state.spin_frame = (state.spin_frame % #SPINNER) + 1
      paint_header()
    end)
  )
end

-- Stop and clean up the spinner timer; repaint the header without the spinner.
local function spinner_stop()
  if state.spin_timer then
    state.spin_timer:stop()
    state.spin_timer:close()
    state.spin_timer = nil
  end
  paint_header()
end

-- Single switch for the loading state: drives the spinner for both views.
local function set_loading(on)
  state.loading = on
  if on then
    spinner_start()
  else
    spinner_stop()
  end
end

-- Resolve owner/repo once (cached), then run `next`.
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

-- Classify a job (REST shape) into a KIND bucket + a status label.
local function classify_job(j)
  if ACTIVE_STATUS[j.status] then
    if j.status == "in_progress" then
      return "running", "in_progress"
    end
    return "queued", "queued"
  end
  -- Completed: bucket by conclusion (cancelled is its own bucket).
  local kind = CONCLUSION_KIND[j.conclusion or ""] or "unknown"
  local label = j.conclusion or j.status or "completed"
  return kind, label
end

-- Queue view: a full processing-order list of recent CI jobs.
-- Ordering: active jobs first, oldest-first (the next ones to run), then
-- completed jobs after them, most-recent-first. Cancelled jobs included.
local function refresh_queue()
  if not is_open() then
    return
  end
  set_loading(true)
  state.cwd = repo_dir()

  with_repo(function()
    gh({
      "run",
      "list",
      "--json",
      "databaseId,status,conclusion,workflowName,name,headBranch,number,displayTitle,createdAt,event",
      "--limit",
      "100",
    }, {}, function(ok, runs, err)
      if not ok then
        set_loading(false)
        if is_open() then
          apply(nil, nil, err)
        end
        return
      end

      -- Take active runs plus the most recent runs overall (run list is already
      -- newest-first), capped so the per-run jobs fan-out stays bounded.
      local selected, seen = {}, {}
      local function pick(run)
        if not seen[run.databaseId] then
          seen[run.databaseId] = true
          selected[#selected + 1] = run
        end
      end
      for _, run in ipairs(runs or {}) do
        if ACTIVE_STATUS[run.status] then
          pick(run)
        end
      end
      for _, run in ipairs(runs or {}) do
        if #selected >= config.queue_runs then
          break
        end
        pick(run)
      end

      if #selected == 0 then
        set_loading(false)
        if is_open() then
          apply({}, nil, nil)
        end
        return
      end

      -- Fan out a jobs fetch per selected run; collect jobs, then sort.
      local jobs = {}
      local pending = #selected

      local function finish()
        table.sort(jobs, function(a, b)
          -- Active jobs come before completed ones.
          if a.active ~= b.active then
            return a.active
          end
          if a.active then
            -- Among active: oldest-first = next to be processed.
            if a.created ~= b.created then
              return (a.created or "") < (b.created or "")
            end
            return (a.name or "") < (b.name or "")
          end
          -- Among completed: most recent first.
          if a.created ~= b.created then
            return (a.created or "") > (b.created or "")
          end
          return (a.name or "") < (b.name or "")
        end)
        set_loading(false)
        if is_open() then
          apply(jobs, nil, nil)
        end
      end

      for _, run in ipairs(selected) do
        gh({
          "api",
          string.format("repos/{owner}/{repo}/actions/runs/%d/jobs", run.databaseId),
        }, {}, function(ok2, data)
          if ok2 and data and data.jobs then
            for _, j in ipairs(data.jobs) do
              local active = ACTIVE_STATUS[j.status] or false
              local kind, label = classify_job(j)
              jobs[#jobs + 1] = {
                name = j.name or run.workflowName or run.name,
                branch = j.head_branch or run.headBranch,
                kind = kind,
                label = label,
                active = active,
                run_id = run.databaseId,
                url = j.html_url or run.url,
                -- For active jobs created_at (enqueue time) drives order; for
                -- completed jobs we sort newest-first on the same field.
                created = j.started_at or j.created_at or run.createdAt,
              }
            end
          end
          pending = pending - 1
          if pending == 0 then
            finish()
          end
        end)
      end
    end)
  end)
end

-- Orchestrate the fetches: repo name -> PRs -> required contexts per base.
local function refresh_board()
  if not is_open() then
    return
  end
  set_loading(true)
  state.cwd = repo_dir()

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
        set_loading(false)
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
        set_loading(false)
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

-- Refresh whichever view is currently active.
local function refresh()
  if state.view == "queue" then
    refresh_queue()
  else
    refresh_board()
  end
end

-- Switch between the board and queue views, repaint immediately, then refetch.
local function toggle_view()
  state.view = state.view == "queue" and "board" or "queue"
  apply({}, {}, nil) -- clear stale rows from the other view
  refresh()
end

local function action_under_cursor()
  local row = vim.api.nvim_win_get_cursor(state.win)[1] - 1
  return state.line_actions[row]
end

-- Re-run the Actions run for the row under the cursor.
-- failed_only=true reruns just the failed jobs (`gh run rerun <id> --failed`).
local function rerun_under_cursor(failed_only)
  local a = action_under_cursor()
  local run_id = a and a.run_id
  if not run_id then
    vim.notify("gh-pipeline: no run under cursor to re-run", vim.log.levels.WARN)
    return
  end
  local args = { "run", "rerun", tostring(run_id) }
  if failed_only then
    args[#args + 1] = "--failed"
  end
  local what = failed_only and "failed jobs of run" or "run"
  vim.notify(string.format("gh-pipeline: re-running %s #%s…", what, run_id), vim.log.levels.INFO)
  state.cwd = repo_dir()
  gh(args, { raw = true }, function(ok, _, err)
    if not ok then
      vim.notify("gh-pipeline: rerun failed: " .. (err or "unknown"), vim.log.levels.ERROR)
      return
    end
    vim.notify(string.format("gh-pipeline: re-run queued for #%s", run_id), vim.log.levels.INFO)
    refresh() -- surface the newly-queued run
  end)
end

local function close()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  -- Stop the spinner timer too (don't repaint -- the buffer is going away).
  if state.spin_timer then
    state.spin_timer:stop()
    state.spin_timer:close()
    state.spin_timer = nil
  end
  state.loading = false
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
  map("R", function()
    rerun_under_cursor(false)
  end)
  map("F", function()
    rerun_under_cursor(true)
  end)
  map("<Tab>", toggle_view)
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
    GhPipelineCancelled = "Comment",
    GhPipelineExpected = "DiagnosticWarn",
    GhPipelinePR = "Title",
    GhPipelineBlocked = "DiagnosticWarn",
    GhPipelineClean = "DiagnosticOk",
  }
  for name, link in pairs(defs) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

function M.open(view)
  if vim.fn.executable("gh") == 0 then
    vim.notify("gh-pipeline: `gh` CLI not found on PATH", vim.log.levels.ERROR)
    return
  end
  state.view = (view == "queue") and "queue" or "board"
  if is_open() then
    apply({}, {}, nil) -- already open: just switch to the requested view
    refresh()
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
    M.open("board")
  end, { desc = "GitHub: PRs blocking merge + required-check state" })
  vim.api.nvim_create_user_command("GhPipelineQueue", function()
    M.open("queue")
  end, { desc = "GitHub: CI jobs in processing order (queued/in-progress)" })
end

return M
