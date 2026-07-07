-- gh-pipeline: a PR-blocker board for GitHub.
-- Floating window listing open PRs and, per PR, every REQUIRED status check with
-- its state -- including "expected, never reported" required checks that silently
-- block a merge (invisible to both `gh run list` and `gh pr checks`).
-- Shells out to the `gh` CLI (reuses gh auth).

local M = {}

local config = {
  refresh_ms = 30000, -- auto-refresh cadence while the float is open
  limit = 50, -- max open PRs to scan
  author = "@me", -- whose PRs to show: "@me", a username, or false for all
  show_passing = false, -- list every passing check, or collapse them to a summary
  width = 0.7, -- float size as a fraction of the editor
  height = 0.7,
  queue_runs = 25, -- max recent runs to fetch jobs for in the queue view
  ai_model = nil, -- claude model for the fuzzy check (nil = claude's default)
  ai_diff_max = 60000, -- max bytes of PR diff fed to claude (keeps token cost bounded)
  -- A PR's unresolved review feedback is flagged as a "long discussion" when it
  -- has at least this many unresolved threads OR this many total thread comments.
  -- Inline threads are usually short, so the aggregate is what matters.
  busy_threads = 4,
  busy_comments = 8,
}

local ns = vim.api.nvim_create_namespace("gh_pipeline")

-- Live UI state for the single floating panel.
local state = {
  buf = nil,
  win = nil,
  timer = nil,
  repo = nil, -- owner/repo, cached
  viewer = nil, -- the authenticated user's login, cached (for "your turn" logic)
  line_actions = {}, -- 0-indexed buffer line -> { url = ... }
  line_pr = {}, -- 0-indexed buffer line -> the pr table it belongs to (board view)
  loading = false,
  view = "board", -- "board" (PR blockers) or "queue" (CI jobs in processing order)
  spin_timer = nil, -- drives the loading spinner animation
  spin_frame = 1,
  req = 0, -- monotonic fetch token; see bump_req
  threads = {}, -- pr number -> unresolved review-thread count (batched GraphQL)
  comments = {}, -- pr number -> total conversation comment count (batched GraphQL)
  issues = {}, -- pr number -> { linked issue numbers } it closes (batched GraphQL)
  reviewers = {}, -- pr number -> { { login, state } } latest review per person (batched GraphQL)
  reviews_n = {}, -- pr number -> total review submissions, the main feedback channel (batched GraphQL)
  compare = {}, -- pr number -> { ahead, behind } vs base branch (per-PR compare API)
  convo = {}, -- pr number -> { { n, authors, path } } per unresolved thread (deadlock detector)
  convo_ai = {}, -- "prnum:sig" -> claude thread-triage result (on-demand, auto-invalidated)
  convo_inflight = {}, -- pr number -> true while a thread triage is running
  board_prs = nil, -- last rendered board data, so AI results can re-render without refetch
  board_required = nil,
  ai = {}, -- headRefOid -> claude verdict table (cached fuzzy check, survives refresh)
  ai_inflight = {}, -- headRefOid -> true while a claude check is running
  paused = false, -- when true, the auto-refresh timer is a no-op (toggle with `p`)
}

-- Bump the request token. Every refresh and view toggle calls this so that
-- in-flight `gh` callbacks from a superseded fetch (e.g. the old view's data
-- arriving after a Tab switch) can compare their captured token against
-- state.req and skip applying -- otherwise queue jobs can be fed to the board
-- builder (and vice versa), crashing the sort on missing fields.
local function bump_req()
  state.req = state.req + 1
  return state.req
end

-- Braille spinner frames, advanced on a short timer while a fetch is in flight.
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- Header decoration shown while loading: animated spinner, else nothing.
local function spinner_text()
  if not state.loading then
    return ""
  end
  return "   " .. SPINNER[state.spin_frame] .. " refreshing…"
end

-- The full header trailer: a "paused" badge (auto-refresh off) plus the spinner.
local function header_suffix()
  return (state.paused and "   ⏸ paused" or "") .. spinner_text()
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
  pass = { icon = "", hl = "GhPipelinePass" },
  fail = { icon = "", hl = "GhPipelineFail" },
  running = { icon = "", hl = "GhPipelineRunning" },
  queued = { icon = "", hl = "GhPipelineQueued" },
  cancelled = { icon = "", hl = "GhPipelineCancelled" },
  expected = { icon = "", hl = "GhPipelineExpected" },
  unknown = { icon = "", hl = "Comment" },
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
-- per-PR signals: verdict, review state, hygiene
-- ---------------------------------------------------------------------------

-- The synthesized "what's blocking this / whose turn is it" verdict. rank
-- drives sort order (lower = more urgent / needs you); icon + hl drive display.
local VERDICT = {
  your_turn = { rank = 0, icon = "⚑", hl = "GhPipelineYourTurn" },
  blocked = { rank = 1, icon = "✗", hl = "GhPipelineFail" },
  waiting = { rank = 2, icon = "◐", hl = "GhPipelineWaiting" },
  draft = { rank = 3, icon = "✎", hl = "GhPipelineDraft" },
  ready = { rank = 4, icon = "✓", hl = "GhPipelineReady" },
  unknown = { rank = 5, icon = "•", hl = "Comment" },
}

-- claude concern_level -> highlight for the AI fuzzy-check rows.
local AI_HL = {
  none = "GhPipelineReady",
  low = "Comment",
  medium = "GhPipelineYourTurn",
  high = "GhPipelineFail",
}

-- Status icons (Nerd Font glyphs), one cell each so the descriptions that follow
-- line up into a column. status key -> { text, hl }. Requires a Nerd Font.
local TAG = {
  pass = { text = "", hl = "GhPipelineReady" },
  fail = { text = "", hl = "GhPipelineFail" },
  warn = { text = "", hl = "GhPipelineYourTurn" },
  wait = { text = "", hl = "GhPipelineWaiting" },
  busy = { text = "", hl = "GhPipelineWaiting" },
  skip = { text = "", hl = "GhPipelineDraft" },
  unknown = { text = "", hl = "Comment" },
}

-- Map a verdict kind / a check KIND to a boot-log tag status.
local VERDICT_TAG = {
  ready = "pass",
  your_turn = "warn",
  blocked = "fail",
  waiting = "wait",
  draft = "skip",
  unknown = "unknown",
}
local CHECK_TAG = {
  pass = "pass",
  fail = "fail",
  running = "busy",
  queued = "wait",
  expected = "warn",
  cancelled = "skip",
  unknown = "unknown",
}

-- A reviewer's latest review state -> { icon, hl } for the per-reviewer row.
local REVIEW_STATE = {
  APPROVED = { icon = TAG.pass.text, hl = "GhPipelineReady" },
  CHANGES_REQUESTED = { icon = TAG.fail.text, hl = "GhPipelineFail" },
  COMMENTED = { icon = "", hl = "Comment" },
  DISMISSED = { icon = TAG.skip.text, hl = "GhPipelineDraft" },
  PENDING = { icon = TAG.wait.text, hl = "GhPipelineWaiting" },
}

-- Claude's per-thread `kind` -> a boot-log tag status, for the triage drill-down.
local CONVO_TAG = {
  blocking = "fail",
  suggestion = "warn",
  nit = "skip",
  question = "wait",
  praise = "pass",
  discussion = "busy",
}

-- Collapse a PR's reported checks (against its required list) into one CI bucket:
-- "fail" | "running" | "missing" (required but never reported) | "pass" | "none".
local function ci_summary(pr, required)
  local reported = {}
  for _, entry in ipairs(pr.statusCheckRollup or {}) do
    local c = classify(entry)
    if c.name then
      reported[c.name] = c
    end
  end
  local req = required and required[pr.baseRefName]
  local names = (req and req ~= false) and req or vim.tbl_keys(reported)
  if #names == 0 then
    return "none"
  end
  local fail, running, missing, pass = false, false, false, false
  for _, name in ipairs(names) do
    local c = reported[name]
    if not c then
      missing = true
    elseif c.kind == "fail" then
      fail = true
    elseif c.kind == "running" or c.kind == "queued" then
      running = true
    elseif c.kind == "pass" then
      pass = true
    end
  end
  if fail then
    return "fail"
  elseif running then
    return "running"
  elseif missing then
    return "missing"
  elseif pass then
    return "pass"
  end
  return "none"
end

-- Is the authenticated viewer among this PR's requested reviewers?
local function review_requested_from_me(pr)
  if not state.viewer then
    return false
  end
  for _, r in ipairs(pr.reviewRequests or {}) do
    if r.login == state.viewer then
      return true
    end
  end
  return false
end

-- Decide the headline verdict for a PR. `mine` = these are the viewer's own PRs
-- (config.author == "@me"): then "your turn" means fix-ups; otherwise it means
-- a review has been requested from you.
local function compute_verdict(pr, required, mine)
  local unresolved = state.threads[pr.number] or 0
  local ci = ci_summary(pr, required)
  local conflicted = pr.mergeable == "CONFLICTING" or pr.mergeStateStatus == "DIRTY"

  if not mine and review_requested_from_me(pr) then
    return "your_turn", "review requested from you"
  end
  if pr.isDraft then
    return "draft", "draft"
  end
  if conflicted then
    return "your_turn", "merge conflicts — your turn"
  end
  if pr.reviewDecision == "CHANGES_REQUESTED" then
    return "your_turn", "changes requested — your turn"
  end
  if ci == "fail" then
    return "blocked", "CI failing — your turn"
  end
  if unresolved > 0 then
    return "your_turn", string.format("%d unresolved conversation%s — your turn", unresolved, unresolved == 1 and "" or "s")
  end
  if ci == "running" or ci == "missing" then
    return "waiting", "waiting on CI"
  end
  if pr.reviewDecision == "REVIEW_REQUIRED" or #(pr.reviewRequests or {}) > 0 then
    return "waiting", "waiting on review"
  end
  if pr.reviewDecision == "APPROVED" and (ci == "pass" or ci == "none") and not conflicted then
    return "ready", "ready to merge"
  end
  return "unknown", "in progress"
end

-- The per-PR "merge gates" as labeled table rows: { label, text, hl }. Each gate
-- always reports its *satisfied* state too (✓ approved, ✓ no conflicts,
-- ✓ resolved) so a healthy PR reads as green ticks rather than going blank. CI is
-- rendered separately by build() because it carries a sub-list of failing checks.
local function pr_gates(pr)
  local g = {}
  local function row(label, status, desc)
    g[#g + 1] = { label = label, status = status, desc = desc }
  end

  -- Review decision (+ who we're waiting on).
  local rd = pr.reviewDecision
  if rd == "APPROVED" then
    row("review", "pass", "approved")
  elseif rd == "CHANGES_REQUESTED" then
    row("review", "fail", "changes requested")
  elseif rd == "REVIEW_REQUIRED" then
    local reqs = {}
    for _, r in ipairs(pr.reviewRequests or {}) do
      reqs[#reqs + 1] = "@" .. (r.login or r.name or r.slug or "?")
    end
    if #reqs > 0 then
      row("review", "wait", "waiting on " .. table.concat(reqs, ", "))
    else
      row("review", "wait", "review required")
    end
  end

  -- Merge conflicts.
  if pr.mergeable == "CONFLICTING" or pr.mergeStateStatus == "DIRTY" then
    row("merge", "fail", "conflicts")
  elseif pr.mergeable == "MERGEABLE" then
    row("merge", "pass", "no conflicts")
  end

  -- Unresolved review conversations (nil = GraphQL didn't report; stay quiet).
  local unresolved = state.threads[pr.number]
  if unresolved and unresolved > 0 then
    row("threads", "warn", string.format("%d unresolved", unresolved))
  elseif unresolved == 0 then
    row("threads", "pass", "resolved")
  end

  return g
end

-- Human "time since" from an ISO-8601 UTC timestamp (e.g. "2026-06-20T14:03:00Z").
local function rel_time(iso)
  if type(iso) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, s = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return nil
  end
  -- os.time() reads its table as *local* time, but the timestamp is UTC. Correct
  -- by the local/UTC offset. os.time honours the isdst flag and os.date("!*t")
  -- always reports isdst=false, which would cancel the offset during DST -- so we
  -- force isdst=false on BOTH breakdowns to read the true zone offset.
  local as_local = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
  })
  local now = os.time()
  local lt, ut = os.date("*t", now), os.date("!*t", now)
  lt.isdst, ut.isdst = false, false
  local offset = os.difftime(os.time(lt), os.time(ut))
  local diff = now - (as_local + offset)
  if diff < 60 then
    return "just now"
  elseif diff < 3600 then
    return math.floor(diff / 60) .. "m"
  elseif diff < 86400 then
    return math.floor(diff / 3600) .. "h"
  end
  return math.floor(diff / 86400) .. "d"
end

-- Aggregate the review feedback on a PR. The bulk of it usually lives in review
-- submissions (Approve/Request-changes/Comment write-ups) and the timeline, not
-- in inline threads -- so we count all three. Returns the breakdown + a `busy`
-- flag for "long conversation". Mechanical -- no AI.
local function discussion_load(pr)
  local nthreads, tcomments = 0, 0
  for _, t in ipairs(state.convo[pr.number] or {}) do
    nthreads = nthreads + 1
    tcomments = tcomments + (t.n or 0)
  end
  local reviews = state.reviews_n[pr.number] or 0
  local timeline = state.comments[pr.number] or 0
  local volume = reviews + timeline + tcomments
  local busy = nthreads >= config.busy_threads or volume >= config.busy_comments
  return {
    nthreads = nthreads,
    tcomments = tcomments,
    reviews = reviews,
    timeline = timeline,
    volume = volume,
    busy = busy,
  }
end

-- A cache key for a PR's triage that changes when the conversation grows (reviews
-- + timeline + thread comments), so new feedback invalidates a stale AI result.
local function convo_sig(pr)
  local total = (state.reviews_n[pr.number] or 0) + (state.comments[pr.number] or 0)
  for _, t in ipairs(state.convo[pr.number] or {}) do
    total = total + (t.n or 0)
  end
  return pr.number .. ":" .. total
end

-- The non-colored part of the stats line: changed-file count · staleness. The
-- +adds/−dels are rendered separately (colored) by build().
local function hygiene_detail(pr)
  local parts = {}
  if pr.changedFiles and pr.changedFiles > 0 then
    parts[#parts + 1] = pr.changedFiles .. (pr.changedFiles == 1 and " file" or " files")
  end
  local age = rel_time(pr.updatedAt)
  if age then
    parts[#parts + 1] = age
  end
  return table.concat(parts, " · ")
end

-- ---------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------

-- Highlight for a PR header line based on its merge state.
local function merge_hl(s)
  if s == "CLEAN" or s == "HAS_HOOKS" then
    return "GhPipelineClean"
  elseif s == "BLOCKED" or s == "DIRTY" or s == "UNSTABLE" or s == "BEHIND" then
    return "GhPipelineBlocked"
  end
  return "GhPipelinePR"
end

-- GitHub's raw mergeStateStatus values are jargon ("dirty", "unstable", …).
-- Translate them into plain English for the header note.
local MERGE_STATE_LABEL = {
  CLEAN = "mergeable",
  HAS_HOOKS = "mergeable",
  DIRTY = "merge conflicts",
  BLOCKED = "merge blocked",
  BEHIND = "behind base branch",
  UNSTABLE = "non-required checks failing",
  DRAFT = "draft",
  UNKNOWN = "computing mergeability…",
}
local function merge_state_label(s)
  return MERGE_STATE_LABEL[s] or (s and s:lower():gsub("_", " ")) or "?"
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
  return line
end

-- Add a line built from colored segments ({text, hl}), joined by `sep`, each
-- segment keeping its own highlight (byte-column ranges -- mind multibyte icons).
local function add_segments(lines, hls, indent, segments, sep, action)
  local text = indent
  local ranges = {}
  for i, s in ipairs(segments) do
    if i > 1 then
      text = text .. sep
    end
    local c0 = #text
    text = text .. s.text
    if s.hl then
      ranges[#ranges + 1] = { c0 = c0, c1 = #text, hl = s.hl }
    end
  end
  local line = add(lines, hls, text, nil, action)
  for _, r in ipairs(ranges) do
    hls[#hls + 1] = { line = line, hl = r.hl, c0 = r.c0, c1 = r.c1 }
  end
  return line
end

-- prs: array from gh pr list. required: { [base] = {contexts}|false (unavailable) }.
local function build(prs, required, err)
  local lines, hls = {}, {}
  state.line_actions = {}
  state.line_pr = {}

  local repo = state.repo or vim.fs.basename(repo_dir())
  local scope = config.author == "@me" and " (yours)"
    or (config.author and (" (@" .. config.author:gsub("^@", "") .. ")"))
    or ""
  local count = prs and ("  ·  " .. #prs .. " open") or ""
  state.header_base = "  PRs blocking merge — " .. repo .. scope .. count
  add(lines, hls, state.header_base .. header_suffix(), "Title")
  add(lines, hls, "", nil)

  if err then
    add(lines, hls, "  error: " .. err, "GhPipelineFail")
    return lines, hls
  end

  if not prs or #prs == 0 then
    add(lines, hls, "  No open PRs ✓", "GhPipelinePass")
    return lines, hls
  end

  -- Adaptive title width based on the current window.
  local win_w = (state.win and vim.api.nvim_win_is_valid(state.win))
      and vim.api.nvim_win_get_width(state.win)
    or math.floor(vim.o.columns * config.width)
  local title_max = math.max(20, win_w - 11)

  -- Compute each PR's verdict once, then order by it (urgent / your-turn first),
  -- breaking ties by number desc.
  local mine = config.author == "@me"
  for _, pr in ipairs(prs) do
    pr.__vkind, pr.__vlabel = compute_verdict(pr, required, mine)
  end
  table.sort(prs, function(a, b)
    local ra, rb = VERDICT[a.__vkind].rank, VERDICT[b.__vkind].rank
    if ra ~= rb then
      return ra < rb
    end
    return a.number > b.number
  end)

  -- The PR currently being rendered; tag_pr() stamps it onto each buffer line so
  -- the `a` (AI check) keymap can find the PR under the cursor anywhere in its block.
  local cur_pr
  local function tag_pr()
    state.line_pr[#lines - 1] = cur_pr
  end

  -- Key/value table geometry: rows render as "    heading   value", the heading
  -- column padded to LABEL_W (9 fits the longest heading, "reviewers"); sub-rows
  -- (failing checks, AI detail) indent to VCOL so they line up under the value.
  local LABEL_W = 9
  local VCOL = string.rep(" ", 4 + LABEL_W)

  -- One labeled table row: dimmed heading + colored value, aligned.
  local function kv_row(label, value, vhl, action)
    add_segments(lines, hls, "    ", {
      { text = string.format("%-" .. LABEL_W .. "s", label), hl = "GhPipelineLabel" },
      { text = value, hl = vhl },
    }, "", action)
    tag_pr()
  end

  -- A status row: dimmed heading, a colored status icon, then the description in
  -- normal text. `indent` lets check sub-rows drop the heading and align their
  -- icon under the value column.
  local function tag_row(indent, label, status, desc, action)
    local t = TAG[status] or TAG.unknown
    add_segments(lines, hls, indent, {
      { text = string.format("%-" .. LABEL_W .. "s", label), hl = "GhPipelineLabel" },
      { text = t.text, hl = t.hl },
      { text = " " .. desc, hl = nil },
    }, "", action)
    tag_pr()
  end

  -- A single check, shown as a tag row with a blank heading so its tag lines up
  -- in the same column as the gate tags above it. The check's detailsUrl
  -- identifies its Actions run, so carry the run id for `R`/`F`.
  local function check_row(kind, name, suffix, url)
    local action = url and { url = url, run_id = run_id_from_url(url) } or nil
    tag_row("    ", "", CHECK_TAG[kind] or "unknown", name .. (suffix or ""), action)
  end

  for _, pr in ipairs(prs) do
    cur_pr = pr
    -- PR header (title bar): the number is tinted by merge state, then branch→base,
    -- then the raw merge state as a dim lowercase note -- deliberately NOT bracketed
    -- so it doesn't read as one of the [ TAG ] boot-log statuses below it.
    local mstate = merge_state_label(pr.mergeStateStatus)
    add_segments(lines, hls, "  ", {
      { text = string.format("#%-4d ", pr.number), hl = merge_hl(pr.mergeStateStatus) },
      { text = string.format("%s → %s", pr.headRefName or "?", pr.baseRefName or "?"), hl = "GhPipelinePR" },
      { text = "   " .. mstate, hl = "Comment" },
    }, "", { url = pr.url })
    tag_pr()

    if pr.title and pr.title ~= "" then
      local title = pr.title:sub(1, title_max)
      if #pr.title > title_max then
        title = title .. "…"
      end
      kv_row("title", title, "Comment", { url = pr.url })
    end

    -- Verdict (whose turn / what's blocking).
    tag_row("    ", "status", VERDICT_TAG[pr.__vkind] or "unknown", pr.__vlabel, { url = pr.url })

    -- Merge gates, one labeled tag row each (review / merge / threads).
    for _, gate in ipairs(pr_gates(pr)) do
      tag_row("    ", gate.label, gate.status, gate.desc)
    end

    -- Per-reviewer breakdown: each reviewer's latest verdict, icon-coded.
    local revs = state.reviewers[pr.number]
    if revs and #revs > 0 then
      local segs = { { text = string.format("%-" .. LABEL_W .. "s", "reviewers"), hl = "GhPipelineLabel" } }
      for i, rv in ipairs(revs) do
        local rs = REVIEW_STATE[rv.state] or REVIEW_STATE.PENDING
        segs[#segs + 1] = { text = (i > 1 and "  " or "") .. rs.icon .. " @" .. rv.login, hl = rs.hl }
      end
      add_segments(lines, hls, "    ", segs, "")
      tag_pr()
    end

    -- Long discussion: aggregate review feedback across reviews + timeline +
    -- inline threads (mechanical, always on).
    local disc = discussion_load(pr)
    if disc.busy then
      local parts = {}
      if disc.reviews > 0 then
        parts[#parts + 1] = disc.reviews .. (disc.reviews == 1 and " review" or " reviews")
      end
      if disc.timeline > 0 then
        parts[#parts + 1] = disc.timeline .. (disc.timeline == 1 and " comment" or " comments")
      end
      if disc.nthreads > 0 then
        parts[#parts + 1] = disc.nthreads .. (disc.nthreads == 1 and " thread" or " threads")
      end
      tag_row("    ", "discuss", "warn", table.concat(parts, " · ") .. " — long conversation, consider a sync")
    end

    -- Thread triage (on-demand AI): each unresolved thread tagged + an action.
    local sig = convo_sig(pr)
    if state.convo_inflight[pr.number] then
      kv_row("convos", "🤖 analyzing conversations…", "Comment")
    elseif state.convo_ai[sig] then
      local ts = state.convo_ai[sig].threads or {}
      for i, t in ipairs(ts) do
        local flags = {}
        if t.talking_past then
          flags[#flags + 1] = "talking past"
        end
        if t.deadlocked then
          flags[#flags + 1] = "deadlocked"
        end
        local desc = (#flags > 0 and ("[" .. table.concat(flags, ", ") .. "] ") or "")
          .. (t.summary or t.kind or "?")
          .. (t.action and t.action ~= "" and (" → " .. t.action) or "")
        tag_row("    ", i == 1 and "convos" or "", CONVO_TAG[t.kind] or "unknown", desc)
      end
      if #ts == 0 then
        kv_row("convos", "nothing to triage", "Comment")
      end
    elseif disc.volume > 0 then
      kv_row("convos", "press t to triage the conversation", "Comment")
    else
      -- Always show the row (even with nothing to do) so the feature is
      -- discoverable and rows don't appear/disappear between PRs.
      kv_row("convos", "no feedback yet", "Comment")
    end

    -- CI: a `checks` summary row, with problem checks listed beneath it.
    local reported = {}
    for _, entry in ipairs(pr.statusCheckRollup or {}) do
      local c = classify(entry)
      if c.name then
        reported[c.name] = c
      end
    end

    local req = required[pr.baseRefName]
    if req == false then
      kv_row("checks", "required-check list unavailable — needs admin", "Comment")
      for name, c in pairs(reported) do
        check_row(c.kind, name, nil, c.url)
      end
    elseif req and #req > 0 then
      -- Walk required contexts: collapse passes into the summary, list problems.
      local passed, problems = 0, {}
      for _, name in ipairs(req) do
        local c = reported[name]
        if not c then
          problems[#problems + 1] = { "expected", name, " — expected, never reported", nil }
        elseif c.kind == "pass" then
          passed = passed + 1
          if config.show_passing then
            problems[#problems + 1] = { "pass", name, nil, c.url }
          end
        else
          problems[#problems + 1] = { c.kind, name, nil, c.url }
        end
      end
      -- Summary tag: all pass -> green, all fail -> red, some fail -> orange,
      -- otherwise (only missing/running) flag the silently-missing or running.
      local failed, has_warn, has_busy = 0, false, false
      for _, p in ipairs(problems) do
        if p[1] == "fail" then
          failed = failed + 1
        elseif p[1] == "expected" then
          has_warn = true
        elseif p[1] == "running" or p[1] == "queued" then
          has_busy = true
        end
      end
      local sstatus
      if passed == #req then
        sstatus = "pass"
      elseif failed == #req then
        sstatus = "fail"
      elseif failed > 0 then
        sstatus = "warn"
      else
        sstatus = has_warn and "warn" or has_busy and "busy" or "wait"
      end
      local all = passed == #req
      local summary = all and string.format("all %d required passed", #req)
        or string.format("%d/%d required passed", passed, #req)
      tag_row("    ", "checks", sstatus, summary)
      for _, p in ipairs(problems) do
        check_row(p[1], p[2], p[3], p[4])
      end
    elseif next(reported) then
      -- No branch protection; list reported checks plainly under the summary.
      kv_row("checks", "no branch protection", "Comment")
      for name, c in pairs(reported) do
        check_row(c.kind, name, nil, c.url)
      end
    else
      kv_row("checks", "no checks reported", "Comment")
    end

    -- Commits ahead/behind base -- flags a branch that needs a rebase.
    local cmp = state.compare[pr.number]
    if cmp and (cmp.ahead or cmp.behind) then
      local txt = string.format("%d ahead · %d behind", cmp.ahead or 0, cmp.behind or 0)
      kv_row("commits", txt, (cmp.behind or 0) > 0 and "GhPipelineYourTurn" or "Comment")
    end

    -- Linked issues this PR closes.
    local iss = state.issues[pr.number]
    if iss and #iss > 0 then
      local refs = {}
      for _, n in ipairs(iss) do
        refs[#refs + 1] = "#" .. n
      end
      kv_row("closes", table.concat(refs, ", "), "Comment")
    end

    -- Stats: diff size (+adds green / −dels red) · files · staleness · comments.
    -- Built as segments so the additions/deletions get their own colors.
    local rest = hygiene_detail(pr)
    local cc = state.comments[pr.number]
    if cc and cc > 0 then
      rest = (rest ~= "" and (rest .. " · ") or "") .. cc .. (cc == 1 and " comment" or " comments")
    end
    local has_size = pr.additions ~= nil or pr.deletions ~= nil
    if has_size or rest ~= "" then
      local segs = { { text = string.format("%-" .. LABEL_W .. "s", "stats"), hl = "GhPipelineLabel" } }
      if has_size then
        segs[#segs + 1] = { text = "+" .. (pr.additions or 0), hl = "GhPipelineAdd" }
        segs[#segs + 1] = { text = " ", hl = nil }
        segs[#segs + 1] = { text = "−" .. (pr.deletions or 0), hl = "GhPipelineDel" }
      end
      if rest ~= "" then
        segs[#segs + 1] = { text = (has_size and " · " or "") .. rest, hl = "Comment" }
      end
      add_segments(lines, hls, "    ", segs, "")
      tag_pr()
    end

    -- Labels.
    local labels = {}
    for _, l in ipairs(pr.labels or {}) do
      labels[#labels + 1] = l.name
    end
    if #labels > 0 then
      kv_row("labels", table.concat(labels, ", "), "Comment")
    end

    -- Claude fuzzy check: in-flight spinner, or cached verdict keyed by head SHA.
    local oid = pr.headRefOid
    if oid and state.ai_inflight[oid] then
      kv_row("ai", "🤖 analyzing diff…", "Comment")
    elseif oid and state.ai[oid] then
      local ai = state.ai[oid]
      local hl = AI_HL[ai.concern_level] or "Comment"

      -- Headline: change type + overall concern level.
      local bits = { ai.type or "?" }
      if ai.concern_level and ai.concern_level ~= "none" then
        bits[#bits + 1] = ai.concern_level
      end
      kv_row("ai", "🤖 " .. table.concat(bits, " · "), hl)

      -- Explicit tests verdict -- the whole point of the check: did a behavioral
      -- change (bugfix/feature) add tests? Always stated, never buried.
      local behavioral = ai.type == "bugfix" or ai.type == "feature"
      if ai.tests_changed == true then
        tag_row("    ", "tests", "pass", "added")
      elseif ai.tests_changed == false then
        if behavioral then
          -- A fix/feature that ships no tests is treated as a hard blocker.
          tag_row("    ", "tests", "fail", "none added — expected for a " .. ai.type)
        else
          tag_row("    ", "tests", "skip", "none (not a fix/feature)")
        end
      else
        tag_row("    ", "tests", "unknown", "unknown")
      end

      -- Suggested specialist reviews (UX / QA / docs), one row each with reason.
      for i, rv in ipairs(ai.reviews or {}) do
        if i > 3 then
          break
        end
        local label = i == 1 and "reviews" or ""
        local rtype = (rv.type or "?"):upper()
        local desc = rtype .. (rv.reason and rv.reason ~= "" and (" — " .. rv.reason) or "")
        tag_row("    ", label, "warn", desc)
      end

      if ai.summary and ai.summary ~= "" then
        add(lines, hls, VCOL .. ai.summary, "Comment")
        tag_pr()
      end
      for i, c in ipairs(ai.concerns or {}) do
        if i > 4 then
          break
        end
        add(lines, hls, VCOL .. "- " .. c, hl)
        tag_pr()
      end
    elseif oid then
      -- Not analyzed yet: always show the row so the feature is discoverable, and
      -- say how to run it.
      tag_row("    ", "ai", "unknown", "no analysis yet — press a to evaluate")
    else
      tag_row("    ", "ai", "unknown", "unavailable (no head commit)")
    end

    add(lines, hls, "", nil)
  end

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
  add(lines, hls, state.header_base .. header_suffix(), "Title")
  add(lines, hls, "", nil)

  if err then
    add(lines, hls, "  error: " .. err, "GhPipelineFail")
    return lines, hls
  end

  if not jobs or #jobs == 0 then
    add(lines, hls, "  No recent jobs ✓", "GhPipelinePass")
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

  return lines, hls
end

-- ---------------------------------------------------------------------------
-- window plumbing
-- ---------------------------------------------------------------------------

local function is_open()
  return state.win and vim.api.nvim_win_is_valid(state.win)
end

-- The keybinding help, shown pinned in the window's border footer (so it never
-- scrolls off with a long list). Keys differ per view.
local function footer_text()
  if state.view == "queue" then
    return " <CR> open · R/F rerun · r refresh · p pause · Tab board · q quit "
  end
  return " <CR> open · a/A ai · t triage · R/F rerun · r refresh · p pause · Tab queue · q quit "
end

-- Push the current footer text onto the floating window's border (dimmed).
local function update_footer()
  if is_open() then
    pcall(vim.api.nvim_win_set_config, state.win, {
      footer = { { footer_text(), "Comment" } },
      footer_pos = "center",
    })
  end
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
    vim.api.nvim_buf_add_highlight(state.buf, ns, h.hl, h.line, h.c0 or 0, h.c1 or -1)
  end

  update_footer()
end

-- Repaint only the header line (line 0) with the current spinner frame. Cheap
-- enough to run on the spinner's fast timer without touching the rest/cursor.
local function paint_header()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf) and state.header_base) then
    return
  end
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, 1, false, { state.header_base .. header_suffix() })
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

-- Fetch the set of head branches for the user's open PRs (per config.author),
-- so the queue view can be scoped to "my own PRs". Calls cb(set) where set is a
-- table keyed by branch name. cb(nil) means "don't filter" -- either the author
-- filter is off, or we couldn't determine the PRs (better to show the full
-- queue than to silently hide everything). An empty set is meaningful: the
-- author simply has no open PRs, so the queue should be empty.
local function my_pr_branches(cb)
  if not config.author then
    return cb(nil)
  end
  gh({
    "pr",
    "list",
    "--state",
    "open",
    "--author",
    config.author,
    "--limit",
    tostring(config.limit),
    "--json",
    "headRefName",
  }, {}, function(ok, prs)
    if not ok or type(prs) ~= "table" then
      return cb(nil)
    end
    local set = {}
    for _, pr in ipairs(prs) do
      if pr.headRefName then
        set[pr.headRefName] = true
      end
    end
    cb(set)
  end)
end

-- Queue view: a processing-order list of recent CI jobs, scoped to the user's
-- own PRs (config.author) by head branch.
-- Ordering: active jobs first, oldest-first (the next ones to run), then
-- completed jobs after them, most-recent-first. Cancelled jobs included.
local function refresh_queue()
  if not is_open() then
    return
  end
  local req = bump_req()
  set_loading(true)
  state.cwd = repo_dir()

  with_repo(function()
    my_pr_branches(function(branchset)
      if req ~= state.req then
        return -- a newer refresh/toggle superseded this fetch
      end
      gh({
        "run",
        "list",
        "--json",
        "databaseId,status,conclusion,workflowName,name,headBranch,number,displayTitle,createdAt,event",
        "--limit",
        "100",
      }, {}, function(ok, runs, err)
        if req ~= state.req then
          return -- a newer refresh/toggle superseded this fetch
        end
        if not ok then
          set_loading(false)
          if is_open() then
            apply(nil, nil, err)
          end
          return
        end

        -- Scope to the user's own PRs: keep only runs whose head branch matches
        -- one of their open PRs. branchset == nil means "no filter".
        local mine = runs or {}
        if branchset then
          mine = {}
          for _, run in ipairs(runs or {}) do
            if run.headBranch and branchset[run.headBranch] then
              mine[#mine + 1] = run
            end
          end
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
        for _, run in ipairs(mine) do
          if ACTIVE_STATUS[run.status] then
            pick(run)
          end
        end
        for _, run in ipairs(mine) do
          if #selected >= config.queue_runs then
            break
          end
          pick(run)
        end

        if #selected == 0 then
          if req ~= state.req then
            return -- a newer refresh/toggle superseded this fetch
          end
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
          if req ~= state.req then
            return -- a newer refresh/toggle superseded this fetch
          end
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
  end)
end

-- Orchestrate the fetches: repo name -> PRs -> required contexts per base.
local function refresh_board()
  if not is_open() then
    return
  end
  local req = bump_req()
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
      "number,title,headRefName,baseRefName,mergeStateStatus,url,statusCheckRollup,"
        .. "reviewDecision,isDraft,mergeable,reviewRequests,labels,additions,deletions,"
        .. "changedFiles,updatedAt,headRefOid",
    }
    if config.author then
      vim.list_extend(args, { "--author", config.author })
    end
    gh(args, {}, function(ok, prs, err)
      if req ~= state.req then
        return -- a newer refresh/toggle superseded this fetch
      end
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

      -- Accumulate into locals; publish to shared state only in finish() so a
      -- superseded fetch can't corrupt a newer one's data.
      local required = {}
      local threads, comments, issues, reviewers, compare, convo = {}, {}, {}, {}, {}, {}
      local reviews_n = {}
      local viewer_login
      -- pending: one GraphQL call + one required-checks call per base + one
      -- compare call per PR (for ahead/behind vs base).
      local pending = 1 + #bases + #prs

      local function finish()
        if req ~= state.req then
          return -- a newer refresh/toggle superseded this fetch
        end
        state.threads, state.comments, state.issues = threads, comments, issues
        state.reviewers, state.compare, state.convo = reviewers, compare, convo
        state.reviews_n = reviews_n
        if viewer_login then
          state.viewer = viewer_login
        end
        state.board_prs, state.board_required = prs, required
        set_loading(false)
        if is_open() then
          apply(prs, required, nil)
        end
      end

      local function done()
        pending = pending - 1
        if pending == 0 then
          finish()
        end
      end

      -- One batched GraphQL call gathers everything not exposed by `gh pr list`:
      -- the viewer login (for "your turn" logic), and per-PR unresolved review
      -- threads, comment count, linked issues, and latest review per reviewer.
      -- first:100 PRs / first:50 threads is a pragmatic cap.
      local owner, name = nil, nil
      if state.repo then
        owner, name = state.repo:match("([^/]+)/(.+)")
      end
      if not owner then
        done()
      else
        local q = "query($o:String!,$r:String!){viewer{login} "
          .. "repository(owner:$o,name:$r){pullRequests(states:OPEN,first:100){nodes{number "
          .. "reviewThreads(first:50){nodes{isResolved path comments(first:100){totalCount nodes{author{login}}}}} "
          .. "comments{totalCount} "
          .. "reviews{totalCount} "
          .. "closingIssuesReferences(first:10){nodes{number}} "
          .. "latestReviews(first:30){nodes{author{login} state}}}}}}"
        gh({ "api", "graphql", "-f", "query=" .. q, "-f", "o=" .. owner, "-f", "r=" .. name }, {}, function(ok2, data)
          local d = ok2 and data and data.data
          if d then
            if d.viewer and d.viewer.login then
              viewer_login = d.viewer.login
            end
            local nodes = ((d.repository or {}).pullRequests or {}).nodes or {}
            for _, node in ipairs(nodes) do
              local num = node.number
              local n, convos = 0, {}
              for _, t in ipairs((node.reviewThreads or {}).nodes or {}) do
                if t.isResolved == false then
                  n = n + 1
                  local cs = (t.comments or {}).nodes or {}
                  local authset, nauth = {}, 0
                  for _, c in ipairs(cs) do
                    local login = c.author and c.author.login
                    if login and not authset[login] then
                      authset[login] = true
                      nauth = nauth + 1
                    end
                  end
                  convos[#convos + 1] = { n = (t.comments or {}).totalCount or #cs, authors = nauth, path = t.path }
                end
              end
              threads[num] = n
              convo[num] = convos
              comments[num] = (node.comments or {}).totalCount or 0
              reviews_n[num] = (node.reviews or {}).totalCount or 0
              local iss = {}
              for _, i in ipairs((node.closingIssuesReferences or {}).nodes or {}) do
                iss[#iss + 1] = i.number
              end
              issues[num] = iss
              local rv = {}
              for _, r in ipairs((node.latestReviews or {}).nodes or {}) do
                if r.author and r.author.login then
                  rv[#rv + 1] = { login = r.author.login, state = r.state }
                end
              end
              reviewers[num] = rv
            end
          end
          done()
        end)
      end

      for _, base in ipairs(bases) do
        gh({
          "api",
          string.format("repos/{owner}/{repo}/branches/%s/protection/required_status_checks", base),
          "-q",
          ".contexts",
        }, {}, function(ok2, contexts)
          required[base] = (ok2 and contexts) or false
          done()
        end)
      end

      -- Per-PR compare for ahead/behind vs base. One REST call each -- bounded by
      -- config.limit, but note it scales with the number of open PRs.
      for _, pr in ipairs(prs) do
        local num = pr.number
        if pr.baseRefName and pr.headRefName then
          gh({
            "api",
            string.format("repos/{owner}/{repo}/compare/%s...%s", pr.baseRefName, pr.headRefName),
          }, {}, function(ok2, data)
            if ok2 and type(data) == "table" then
              compare[num] = { ahead = data.ahead_by, behind = data.behind_by }
            end
            done()
          end)
        else
          done()
        end
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

-- The PR whose block the cursor is in (board view only).
local function pr_under_cursor()
  local row = vim.api.nvim_win_get_cursor(state.win)[1] - 1
  return state.line_pr[row]
end

-- Repaint the board from the last fetched data (no network) -- used when an AI
-- check starts/finishes so its row updates without waiting for a full refresh.
local function rerender_board()
  if state.view == "board" and state.board_prs and is_open() then
    apply(state.board_prs, state.board_required, nil)
  end
end

-- Pull a JSON object out of claude's text output, tolerating ```json fences or
-- stray prose around it.
local function parse_ai_json(text)
  if type(text) ~= "string" then
    return nil
  end
  local ok, v = pcall(vim.json.decode, vim.trim(text))
  if ok and type(v) == "table" then
    return v
  end
  local inner = text:match("(%b{})")
  if inner then
    local ok2, v2 = pcall(vim.json.decode, inner)
    if ok2 and type(v2) == "table" then
      return v2
    end
  end
  return nil
end

-- Fuzzy check for one PR: feed its diff to `claude -p` and ask it to classify the
-- change and flag concerns (e.g. a bugfix with no tests). Guards against
-- double-runs and caches the verdict by head SHA. `quiet` suppresses the per-PR
-- start notification (used by the batch run). Returns true if a check started.
local function run_ai_for(pr, quiet)
  local oid = pr and pr.headRefOid
  if not oid or state.ai_inflight[oid] then
    return false
  end
  state.ai_inflight[oid] = true
  rerender_board()
  if not quiet then
    vim.notify(string.format("gh-pipeline: analyzing #%d with claude…", pr.number), vim.log.levels.INFO)
  end

  local cwd = repo_dir()
  -- Grab the diff first, then hand it to claude on stdin.
  vim.system({ "gh", "pr", "diff", tostring(pr.number) }, { cwd = cwd, text = true }, function(dres)
    local diff = dres.code == 0 and dres.stdout or ""
    if #diff > config.ai_diff_max then
      diff = diff:sub(1, config.ai_diff_max) .. "\n…[diff truncated]…\n"
    end
    local prompt = table.concat({
      "You are reviewing a GitHub pull request to flag risks before merge.",
      "PR title: " .. (pr.title or ""),
      "The unified diff is on stdin.",
      "Reply with STRICT JSON only (no markdown, no prose) matching exactly:",
      '{"type":"bugfix|feature|refactor|docs|test|chore|other",',
      ' "tests_changed":true|false,',
      ' "concern_level":"none|low|medium|high",',
      ' "concerns":["short string", "..."],',
      ' "reviews":[{"type":"ux|qa|docs","reason":"short"}],',
      ' "summary":"one sentence"}',
      "Especially: if this is a bugfix or feature that changes behavior but adds/",
      "changes no tests, flag it. Also flag leftover TODO/FIXME/debug output,",
      "obvious missing error handling, and risky changes lacking coverage.",
      "For `reviews`, recommend a specialist review where warranted (subjective):",
      "ux = the visible appearance/layout/styling of a UI changed; qa = a fix or",
      "behavior change that warrants manual testing; docs = user-facing docs or a",
      "public API changed (especially if docs weren't updated to match). Omit any",
      "that don't apply; use an empty array if none.",
      "At most 4 concerns, each under 90 chars. If nothing stands out use",
      'concern_level "none" and an empty concerns array.',
    }, "\n")

    local cmd = { "claude", "-p", prompt, "--output-format", "json" }
    if config.ai_model then
      vim.list_extend(cmd, { "--model", config.ai_model })
    end
    vim.system(cmd, { cwd = cwd, text = true, stdin = diff }, function(res)
      vim.schedule(function()
        state.ai_inflight[oid] = nil
        if res.code ~= 0 then
          vim.notify("gh-pipeline: claude failed: " .. vim.trim((res.stderr or ""):sub(1, 200)), vim.log.levels.ERROR)
          rerender_board()
          return
        end
        local env = parse_ai_json(res.stdout) -- the --output-format json envelope
        local verdict = env and env.result and parse_ai_json(env.result)
        if not verdict then
          vim.notify("gh-pipeline: couldn't parse claude output", vim.log.levels.ERROR)
          rerender_board()
          return
        end
        state.ai[oid] = verdict
        rerender_board()
      end)
    end)
  end)
  return true
end

-- `a`: analyze the PR under the cursor (re-runs even if cached).
local function ai_check_under_cursor()
  if vim.fn.executable("claude") == 0 then
    vim.notify("gh-pipeline: `claude` CLI not found on PATH", vim.log.levels.ERROR)
    return
  end
  local pr = pr_under_cursor()
  if not (pr and pr.headRefOid) then
    vim.notify("gh-pipeline: no PR under cursor to analyze", vim.log.levels.WARN)
    return
  end
  if state.ai_inflight[pr.headRefOid] then
    vim.notify("gh-pipeline: already analyzing this PR", vim.log.levels.INFO)
    return
  end
  run_ai_for(pr, false)
end

-- `A`: refresh the board AND run the AI check on every PR lacking one. Spawns one
-- `claude` per PR, so it can be slow/costly on a big board; already-analyzed PRs
-- are skipped (use `a` to re-run a single one).
local function refresh_and_ai_all()
  refresh()
  if vim.fn.executable("claude") == 0 then
    vim.notify("gh-pipeline: `claude` CLI not found on PATH", vim.log.levels.ERROR)
    return
  end
  local started = 0
  for _, pr in ipairs(state.board_prs or {}) do
    if pr.headRefOid and not state.ai[pr.headRefOid] and run_ai_for(pr, true) then
      started = started + 1
    end
  end
  if started > 0 then
    vim.notify(
      string.format("gh-pipeline: analyzing %d PR%s with claude…", started, started == 1 and "" or "s"),
      vim.log.levels.INFO
    )
  else
    vim.notify("gh-pipeline: all PRs already analyzed", vim.log.levels.INFO)
  end
end

-- `t`: triage the unresolved review conversations on the PR under the cursor.
-- Fetches each thread's comments, asks claude to tag kind/talking-past/deadlock
-- and suggest an action. On-demand, cached by conversation signature.
local function triage_convo_under_cursor()
  if vim.fn.executable("claude") == 0 then
    vim.notify("gh-pipeline: `claude` CLI not found on PATH", vim.log.levels.ERROR)
    return
  end
  local pr = pr_under_cursor()
  if not pr then
    vim.notify("gh-pipeline: no PR under cursor", vim.log.levels.WARN)
    return
  end
  local num = pr.number
  if state.convo_inflight[num] then
    vim.notify("gh-pipeline: already triaging this PR", vim.log.levels.INFO)
    return
  end
  local owner, name = nil, nil
  if state.repo then
    owner, name = state.repo:match("([^/]+)/(.+)")
  end
  if not owner then
    vim.notify("gh-pipeline: repo not resolved yet", vim.log.levels.WARN)
    return
  end
  state.convo_inflight[num] = true
  rerender_board()
  vim.notify(string.format("gh-pipeline: triaging #%d conversations…", num), vim.log.levels.INFO)

  local cwd = repo_dir()
  -- The conversation lives across three channels: the timeline, review write-ups
  -- (the main feedback), and unresolved inline threads. Pull them all.
  local q = "query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){"
    .. "comments(first:60){nodes{author{login} body}} "
    .. "reviews(first:60){nodes{author{login} state body}} "
    .. "reviewThreads(first:50){nodes{isResolved path comments(first:50){nodes{author{login} body}}}}}}}"
  gh({ "api", "graphql", "-f", "query=" .. q, "-f", "o=" .. owner, "-f", "r=" .. name, "-F", "n=" .. num }, {}, function(ok, data)
    -- Assemble the whole conversation into labelled sections for claude.
    local blocks, idx = {}, 0
    if ok and data and data.data then
      local prd = (data.data.repository or {}).pullRequest or {}

      local tl = (prd.comments or {}).nodes or {}
      if #tl > 0 then
        local buf = { "=== TIMELINE CONVERSATION ===" }
        for _, c in ipairs(tl) do
          buf[#buf + 1] = "@" .. ((c.author or {}).login or "?") .. ": " .. (c.body or "")
        end
        blocks[#blocks + 1] = table.concat(buf, "\n")
        idx = idx + 1
      end

      for _, rv in ipairs((prd.reviews or {}).nodes or {}) do
        if rv.body and rv.body ~= "" then
          blocks[#blocks + 1] = string.format(
            "=== REVIEW by @%s (%s) ===\n%s",
            (rv.author or {}).login or "?",
            rv.state or "?",
            rv.body
          )
          idx = idx + 1
        end
      end

      -- Include resolved threads too: in a healthy review most conversation
      -- lives in threads that got addressed and resolved, and dropping them
      -- left nothing to triage. Label the state so claude can mark settled
      -- ones `resolve` rather than treating them as open.
      for _, th in ipairs((prd.reviewThreads or {}).nodes or {}) do
        local cs = (th.comments or {}).nodes or {}
        if #cs > 0 then
          local buf = {
            string.format(
              "=== INLINE THREAD (%s)%s ===",
              th.path or "?",
              th.isResolved and " [resolved]" or ""
            ),
          }
          for _, c in ipairs(cs) do
            buf[#buf + 1] = "@" .. ((c.author or {}).login or "?") .. ": " .. (c.body or "")
          end
          blocks[#blocks + 1] = table.concat(buf, "\n")
          idx = idx + 1
        end
      end
    end

    if idx == 0 then
      vim.schedule(function()
        state.convo_inflight[num] = nil
        state.convo_ai[convo_sig(pr)] = { threads = {} }
        rerender_board()
      end)
      return
    end

    local prompt = table.concat({
      "You are helping a PR author triage the review conversation. The feedback is",
      'on stdin in sections separated by "=== ... ===": the timeline conversation,',
      "each REVIEW write-up (with its state), and each INLINE THREAD (threads",
      "marked [resolved] were already settled — prefer action=resolve for those).",
      "Reply with STRICT JSON only (no markdown):",
      '{"threads":[{"id":n,"kind":"blocking|suggestion|nit|question|praise|discussion",',
      ' "talking_past":true|false,"deadlocked":true|false,',
      ' "action":"reply|defer|resolve|sync|escalate","summary":"<=70 chars, neutral"}]}',
      "Identify each distinct discussion point or disagreement (not necessarily one",
      "per section; merge related ones). kind=nit for trivial/style/subjective",
      "preferences that don't block merge. talking_past=true if replies don't address",
      "the prior point, OR the people already agree but keep going. deadlocked=true if",
      "it's circular/stalemate. action: resolve = already addressed; defer = a nit for",
      "later; sync = take it to a call; escalate = needs a maintainer decision.",
      "Keep summaries short and neutral.",
    }, "\n")

    local cmd = { "claude", "-p", prompt, "--output-format", "json" }
    if config.ai_model then
      vim.list_extend(cmd, { "--model", config.ai_model })
    end
    vim.system(cmd, { cwd = cwd, text = true, stdin = table.concat(blocks, "\n\n") }, function(res)
      vim.schedule(function()
        state.convo_inflight[num] = nil
        if res.code ~= 0 then
          vim.notify("gh-pipeline: claude failed: " .. vim.trim((res.stderr or ""):sub(1, 200)), vim.log.levels.ERROR)
          rerender_board()
          return
        end
        local env = parse_ai_json(res.stdout)
        local verdict = env and env.result and parse_ai_json(env.result)
        if not (verdict and type(verdict.threads) == "table") then
          vim.notify("gh-pipeline: couldn't parse claude output", vim.log.levels.ERROR)
          rerender_board()
          return
        end
        state.convo_ai[convo_sig(pr)] = verdict
        rerender_board()
      end)
    end)
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
  map("a", ai_check_under_cursor)
  map("A", refresh_and_ai_all)
  map("t", triage_convo_under_cursor)
  map("p", function()
    state.paused = not state.paused
    vim.notify("gh-pipeline: auto-refresh " .. (state.paused and "paused" or "resumed"), vim.log.levels.INFO)
    paint_header()
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
    GhPipelineYourTurn = "DiagnosticWarn",
    GhPipelineWaiting = "DiagnosticInfo",
    GhPipelineDraft = "Comment",
    GhPipelineReady = "DiagnosticOk",
    GhPipelineLabel = "Identifier", -- the dimmed left-hand row headings
    GhPipelineAdd = "DiagnosticOk", -- +additions in the stats line (green)
    GhPipelineDel = "DiagnosticError", -- −deletions in the stats line (red)
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
      if not state.paused then
        refresh()
      end
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
