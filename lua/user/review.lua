-- Review the working tree as inline diffs in ordinary buffers.
--
-- lazygit's diff pane is fine for a glance and hopeless for review: one file at
-- a time, in a pane too narrow to read, with no LSP and nowhere to jump to. This
-- opens every changed file as a real buffer instead and turns gitsigns' inline
-- decorations all the way up, so the diff is rendered in place — changed lines
-- highlighted, removed lines as virtual lines above them, intra-line edits
-- word-diffed — while everything else (gd, hover, editing, staging a hunk with
-- <leader>hs) keeps working.
--
-- The hunks also land in the quickfix list, so ]q / [q walks the whole review
-- across files and <leader>xq renders it as a checklist in Trouble.
--
-- Not a plugin spec: lazy.nvim auto-imports lua/plugins/, which is why this
-- lives under lua/user/ and is required from init.lua.

local M = {}

local state = {
  active = false,
  base = nil, -- revision being diffed against, for the notification/title
  root = nil, -- repo toplevel the review is scoped to
  buffers = {}, -- { bufnr -> was_listed_before_us }, so close() only undoes our own opening
}

local function plural(n, word)
  return n .. " " .. word .. (n == 1 and "" or "s")
end

--- Run git in `root` and return its stdout as lines, or nil plus stderr.
local function git(root, args)
  local cmd = { "git", "-C", root }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { text = true }):wait()
  if res.code ~= 0 then
    return nil, vim.trim(res.stderr or "")
  end
  return vim.split(vim.trim(res.stdout or ""), "\n", { trimempty = true })
end

--- The repo containing the current buffer, falling back to the cwd for buffers
--- with no file behind them (the dashboard, a log window).
local function repo_root()
  local name = vim.api.nvim_buf_get_name(0)
  local dir = name ~= "" and vim.fs.dirname(name) or vim.fn.getcwd()
  if vim.fn.isdirectory(dir) == 0 then
    dir = vim.fn.getcwd()
  end
  local out = git(dir, { "rev-parse", "--show-toplevel" })
  return out and out[1]
end

--- What to diff against. With no argument that is HEAD, not gitsigns' default of
--- the index: the index hides everything already staged, and staged work is
--- exactly what you want to see when reviewing. Given a branch it is the merge
--- base, so the review shows your commits and not whatever landed on the base
--- branch in the meantime.
local function resolve_base(root, rev)
  if not rev or rev == "" then
    return "HEAD", "HEAD"
  end
  local out = git(root, { "merge-base", rev, "HEAD" })
  if out and out[1] then
    return out[1], rev .. " (merge base)"
  end
  return rev, rev -- not an ancestor: a bare commit or a detached ref, diff against it directly
end

--- gitsigns' inline decorations, as a set. The toggles only flip config values,
--- so already-open buffers keep their old extmarks until refresh() re-renders.
--- (show_deleted is deprecated in favour of preview_hunk_inline(), but that is a
--- one-hunk-at-a-time popup; the config flag is the only persistent form.)
local function decorate(on)
  local gs = require("gitsigns")
  gs.toggle_linehl(on)
  gs.toggle_word_diff(on)
  gs.toggle_deleted(on)
  gs.refresh()
end

--- Mark every file in the hunk list as a listed buffer, so the review shows up
--- in bufferline and :ls. setqflist() has already created the buffers (unlisted,
--- unloaded) to resolve its filenames, which is why nothing here reads git.
local function list_buffers(items)
  local files = 0
  for _, item in ipairs(items) do
    local buf = item.bufnr
    if buf and buf ~= 0 and state.buffers[buf] == nil then
      state.buffers[buf] = vim.bo[buf].buflisted
      vim.bo[buf].buflisted = true
      files = files + 1
    end
  end
  return files
end

--- Hunks for the whole repo, from gitsigns rather than a git diff of our own: it
--- honours the base we just set, and one source for the file list and the hunk
--- list cannot disagree with itself. Its "all" target unions every repo it has
--- seen, so entries outside the repo under review are dropped afterwards.
local function collect(title, callback)
  require("gitsigns").setqflist("all", { open = false }, function()
    vim.schedule(function()
      local kept = {}
      for _, item in ipairs(vim.fn.getqflist()) do
        local name = item.bufnr and item.bufnr ~= 0 and vim.api.nvim_buf_get_name(item.bufnr) or ""
        if vim.startswith(name, state.root .. "/") then
          kept[#kept + 1] = item
        end
      end
      vim.fn.setqflist({}, "r", { items = kept, title = title })
      callback(kept)
    end)
  end)
end

local function open_list()
  if package.loaded["trouble"] or pcall(require, "trouble") then
    require("trouble").open({ mode = "qflist", focus = false })
  else
    vim.cmd.copen()
  end
end

--- Start a review of the working tree against `rev` (a branch, tag or commit;
--- HEAD when omitted).
function M.open(rev)
  local root = repo_root()
  if not root then
    vim.notify("not inside a git repository", vim.log.levels.WARN)
    return
  end

  local base, label = resolve_base(root, rev)
  state.root = root
  state.base = label

  local gs = require("gitsigns")
  -- Chained rather than sequential: change_base is async, and the hunk list must
  -- be built after the new base has landed in the config.
  gs.change_base(base, true, function()
    collect("Review vs " .. label, function(items)
      if vim.tbl_isempty(items) then
        gs.reset_base(true)
        state.root, state.base = nil, nil
        vim.notify("no changes vs " .. label, vim.log.levels.INFO)
        return
      end

      local files = list_buffers(items)
      state.active = true
      decorate(true)
      vim.cmd.cfirst()
      open_list()
      vim.notify(("review: %s in %s vs %s"):format(plural(#items, "hunk"), plural(files, "file"), label))
    end)
  end)
end

--- End the review: decorations off, base back to the index, and the buffers the
--- review opened wiped again. Anything modified or still on screen is left
--- listed — you may well have started editing what you were reviewing, and
--- unlisting the buffer you are looking at would drop it out of bufferline while
--- it sits there in the window.
function M.close()
  if not state.active then
    return
  end
  decorate(false)
  require("gitsigns").reset_base(true)

  for buf, was_listed in pairs(state.buffers) do
    if
      not was_listed
      and vim.api.nvim_buf_is_valid(buf)
      and not vim.bo[buf].modified
      and vim.tbl_isempty(vim.fn.win_findbuf(buf))
    then
      pcall(vim.api.nvim_buf_delete, buf, {})
    end
  end

  local label = state.base
  state = { active = false, base = nil, root = nil, buffers = {} }
  vim.notify("review closed (was vs " .. tostring(label) .. ")")
end

function M.toggle(rev)
  if state.active then
    M.close()
  else
    M.open(rev)
  end
end

--- Rebuild the hunk list against the same base, for after staging or editing
--- some of what you are reviewing.
function M.refresh()
  if not state.active then
    vim.notify("no review in progress", vim.log.levels.INFO)
    return
  end
  collect("Review vs " .. state.base, function(items)
    list_buffers(items)
    if vim.tbl_isempty(items) then
      vim.notify("review: nothing left vs " .. state.base)
      return
    end
    open_list()
    vim.notify("review: " .. plural(#items, "hunk") .. " left")
  end)
end

------------------------------------------------------------------- wiring --

--- Branches and tags, for :GitReview completion.
local function complete(arglead)
  local root = state.root or repo_root()
  if not root then
    return {}
  end
  local refs = git(root, { "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/tags", "refs/remotes" })
  return vim.tbl_filter(function(ref)
    return vim.startswith(ref, arglead)
  end, refs or {})
end

function M.setup()
  vim.keymap.set("n", "<leader>gr", function()
    M.toggle()
  end, { desc = "Toggle inline diff review" })
  vim.keymap.set("n", "<leader>gR", M.refresh, { desc = "Refresh the review hunk list" })

  vim.api.nvim_create_user_command("GitReview", function(cmd)
    M.open(cmd.args)
  end, { nargs = "?", complete = complete, desc = "Review changed files as inline diffs" })
  vim.api.nvim_create_user_command("GitReviewOff", function()
    M.close()
  end, { desc = "End the inline diff review" })
end

return M
