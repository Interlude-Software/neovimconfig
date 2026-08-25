-- Live preview for :colorscheme. The scheme under the wildmenu cursor is
-- applied as you tab through the completions, and put back if you abort the
-- command line. Not a plugin spec, so it lives outside lua/plugins/ and is
-- wired up by hand from init.lua.
local M = {}

-- Colorscheme in effect before the preview started, as { name, background }.
-- `previewing` is tracked separately because vim.g.colors_name is nil when no
-- scheme has been loaded, and nil is also "nothing saved".
local saved = nil
local previewing = false

---Name of the colorscheme the command line is currently pointing at, or nil.
---@param line string
---@return string|nil
local function pending_scheme(line)
  local cmd, name = line:match("^%s*(%a+)%s+(%S+)$")
  -- :colo through :colorscheme are all valid, so test the word against the
  -- full command instead of spelling out every abbreviation.
  if not cmd or #cmd < 4 or ("colorscheme"):sub(1, #cmd) ~= cmd then
    return nil
  end
  -- Only apply a scheme that is actually installed; a half-typed name would
  -- otherwise throw on every keystroke.
  if vim.tbl_contains(vim.fn.getcompletion(name, "color"), name) then
    return name
  end
end

local function restore()
  if not previewing then
    return
  end
  previewing = false
  -- 'background' has to go back BEFORE the scheme is re-applied: :colorscheme
  -- never resets it, so a previewed light scheme leaves background=light
  -- behind, and schemes that branch on it then load their light variant --
  -- onedark writes that choice into vim.g.onedark_config and stays light for
  -- the rest of the session.
  if saved then
    vim.o.background = saved.background
    -- Nothing to go back to if no scheme was loaded when the preview started.
    if saved.name then
      pcall(vim.cmd.colorscheme, saved.name)
    end
    vim.cmd.redraw()
  end
  saved = nil
end

function M.setup()
  local group = vim.api.nvim_create_augroup("UserColorPreview", { clear = true })

  vim.api.nvim_create_autocmd("CmdlineChanged", {
    group = group,
    pattern = ":",
    callback = function()
      local name = pending_scheme(vim.fn.getcmdline())
      if not name then
        -- Backspaced past a valid name, or this is no longer a :colorscheme.
        restore()
        return
      end
      if name == vim.g.colors_name then
        return
      end
      if not previewing then
        saved = { name = vim.g.colors_name, background = vim.o.background }
        previewing = true
      end
      if pcall(vim.cmd.colorscheme, name) then
        vim.cmd.redraw()
      end
    end,
  })

  vim.api.nvim_create_autocmd("CmdlineLeave", {
    group = group,
    pattern = ":",
    callback = function()
      if vim.v.event.abort then
        restore()
      end
      -- Accepted: the command itself applies the scheme, so just drop the state.
      saved, previewing = nil, false
    end,
  })
end

return M
