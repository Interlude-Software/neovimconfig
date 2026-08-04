-- A small field form in a floating window: text, integer, checkbox and enum
-- fields, navigated with j/k and edited in place.
--
-- Deliberately not a general widget toolkit — it exists because run profiles need
-- checkboxes for flags and typed fields for values, and driving that through a
-- chain of vim.ui.input prompts is miserable to use and impossible to review
-- before saving. Kept separate from user/run.lua so the layout and key handling
-- can be tested without launching anything.
--
-- Field kinds:
--   section  a non-focusable heading
--   text     free string
--   int      string constrained to an integer on save
--   bool     checkbox; contributes a bare flag when true
--   enum     one of `values`, cycled or picked
--   choice   picked from `values_fn()`, evaluated on open so the list can reflect
--            the state of the world (which executables exist right now)
--
-- Not a plugin spec: see the note at the top of user/build.lua.

local M = {}

local NS = vim.api.nvim_create_namespace("user_form")

--- Sentinel a `choice` entry can carry to mean "let me type it instead", so a
--- picker never becomes a dead end when the wanted value is not on the list.
M.PROMPT = setmetatable({}, {
  __tostring = function()
    return "<prompt>"
  end,
})

local CHECK_INDENT = "  "
local VALUE_INDENT = "      "

--- Label column sized to the longest label present. A fixed width either wastes
--- space or collides with the value, which is exactly what a wide label did.
local function label_width(fields)
  local width = 0
  for _, field in ipairs(fields) do
    if field.kind ~= "section" then
      width = math.max(width, #field.label)
    end
  end
  return math.min(math.max(width + 2, 14), 44)
end

local function is_focusable(field)
  return field.kind ~= "section"
end

local function display_value(field)
  local value = field.value
  if field.kind == "bool" then
    return ""
  end
  if value == nil or value == "" then
    return field.placeholder or "—"
  end
  if field.kind == "enum" then
    return "< " .. tostring(value) .. " >"
  end
  return tostring(value)
end

local function is_placeholder(field)
  return field.kind ~= "bool" and (field.value == nil or field.value == "")
end

local function field_line(field, width)
  if field.kind == "bool" then
    return string.format("%s[%s] %s", CHECK_INDENT, field.value and "x" or " ", field.label)
  end
  return string.format("%s%-" .. width .. "s%s", VALUE_INDENT, field.label, display_value(field))
end

--- Rebuild the buffer from the field list, remembering which line each field
--- occupies so cursor movement can skip headings and separators.
local function render(form)
  local lines = { "" }
  local width = label_width(form.fields)
  form.line_of, form.field_of = {}, {}

  for index, field in ipairs(form.fields) do
    if field.kind == "section" then
      if #lines > 1 then
        lines[#lines + 1] = ""
      end
      lines[#lines + 1] = "  " .. field.label
    else
      lines[#lines + 1] = field_line(field, width)
      form.line_of[index] = #lines
      form.field_of[#lines] = index
    end
  end

  lines[#lines + 1] = ""
  if form.preview then
    local text = form.preview(form) or ""
    lines[#lines + 1] = "  " .. text
  end

  vim.bo[form.buf].modifiable = true
  vim.api.nvim_buf_set_lines(form.buf, 0, -1, false, lines)
  vim.bo[form.buf].modifiable = false

  -- highlighting
  vim.api.nvim_buf_clear_namespace(form.buf, NS, 0, -1)
  local function mark(lnum, col, end_col, hl)
    pcall(vim.api.nvim_buf_set_extmark, form.buf, NS, lnum, col, { end_col = end_col, hl_group = hl })
  end

  for lnum, text in ipairs(lines) do
    local row = lnum - 1
    local index = form.field_of[lnum]
    if index then
      local field = form.fields[index]
      if field.kind == "bool" then
        mark(row, #CHECK_INDENT, #CHECK_INDENT + 3, field.value and "DiagnosticOk" or "Comment")
        mark(row, #CHECK_INDENT + 4, #text, "Identifier")
      else
        mark(row, #VALUE_INDENT, #VALUE_INDENT + width, "Identifier")
        mark(row, #VALUE_INDENT + width, #text, is_placeholder(field) and "Comment" or "String")
      end
    elseif text:match("^  %S") then
      -- section heading or the preview line
      mark(row, 0, #text, lnum == #lines and "Comment" or "Title")
    end
  end

  if form.win and vim.api.nvim_win_is_valid(form.win) then
    local target = form.line_of[form.cursor]
    if target then
      pcall(vim.api.nvim_win_set_cursor, form.win, { target, 0 })
    end
  end
end

local function move(form, delta)
  local index = form.cursor
  while true do
    index = index + delta
    if index < 1 or index > #form.fields then
      return -- keep the cursor where it was rather than wrapping past the ends
    end
    if is_focusable(form.fields[index]) then
      form.cursor = index
      render(form)
      return
    end
  end
end

--- Change a field: toggle a checkbox, cycle an enum, prompt for a value.
local function activate(form, cycle)
  local field = form.fields[form.cursor]
  if not field then
    return
  end

  if field.kind == "bool" then
    field.value = not field.value
    render(form)
    return
  end

  if field.kind == "choice" then
    local prompt_for_value = function()
      vim.ui.input({ prompt = field.label .. ": ", default = tostring(field.value or "") }, function(value)
        if value ~= nil then
          field.value = value
          render(form)
        end
      end)
    end

    local items = field.values_fn and field.values_fn() or {}
    if #items == 0 then
      return prompt_for_value()
    end

    vim.ui.select(items, {
      prompt = field.label,
      format_item = function(item)
        return item.label
      end,
    }, function(item)
      if not item then
        return
      end
      if item.value == M.PROMPT then
        return prompt_for_value()
      end
      field.value = item.value
      render(form)
    end)
    return
  end

  if field.kind == "enum" then
    if cycle then
      local values = field.values or {}
      local at = 1
      for i, v in ipairs(values) do
        if v == field.value then
          at = i
          break
        end
      end
      field.value = values[(at % #values) + 1]
      render(form)
    else
      vim.ui.select(field.values or {}, { prompt = field.label }, function(choice)
        if choice then
          field.value = choice
          render(form)
        end
      end)
    end
    return
  end

  vim.ui.input({ prompt = field.label .. ": ", default = tostring(field.value or "") }, function(value)
    if value ~= nil then
      field.value = value
      render(form)
    end
  end)
end

local function close(form)
  if form.win and vim.api.nvim_win_is_valid(form.win) then
    vim.api.nvim_win_close(form.win, true)
  end
  form.win = nil
end

local function submit(form)
  for _, field in ipairs(form.fields) do
    -- int fields are typed as strings; reject junk here rather than at launch
    if field.kind == "int" and field.value and field.value ~= "" then
      if not tostring(field.value):match("^%-?%d+$") then
        vim.notify(("%s must be a whole number (got %q)"):format(field.label, field.value), vim.log.levels.ERROR)
        return
      end
    end
    if field.required and vim.trim(tostring(field.value or "")) == "" then
      vim.notify(field.label .. " is required", vim.log.levels.ERROR)
      return
    end
  end

  local values = {}
  for _, field in ipairs(form.fields) do
    if field.key then
      values[field.key] = field.value
    end
  end

  -- on_submit runs before the window closes, and returning false keeps it open:
  -- closing first would throw away everything typed whenever a save is rejected.
  if form.on_submit(values, form.fields) == false then
    return
  end
  close(form)
end

--- Open the form. `fields` is mutated in place as the user edits, so callers can
--- read final state from the submit callback rather than tracking it themselves.
function M.open(opts)
  local form = {
    fields = opts.fields,
    preview = opts.preview,
    on_submit = opts.on_submit,
    cursor = 1,
  }

  for index, field in ipairs(form.fields) do
    if is_focusable(field) then
      form.cursor = index
      break
    end
  end

  form.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[form.buf].buftype = "nofile"
  vim.bo[form.buf].filetype = "runform"

  local width = math.min(78, math.max(52, vim.o.columns - 10))
  local height = math.min(#form.fields + 6, vim.o.lines - 6)
  form.win = vim.api.nvim_open_win(form.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. (opts.title or "Form") .. " ",
    title_pos = "center",
    footer = " <CR> edit   <Space> toggle   <C-s> save   q cancel ",
    footer_pos = "center",
  })
  vim.wo[form.win].cursorline = true
  vim.wo[form.win].wrap = false

  local map = function(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = form.buf, nowait = true, silent = true })
  end
  map("j", function()
    move(form, 1)
  end)
  map("k", function()
    move(form, -1)
  end)
  map("<Tab>", function()
    move(form, 1)
  end)
  map("<S-Tab>", function()
    move(form, -1)
  end)
  map("<CR>", function()
    activate(form, false)
  end)
  map("<Space>", function()
    activate(form, true)
  end)
  map("<C-s>", function()
    submit(form)
  end)
  map("q", function()
    close(form)
  end)
  map("<Esc>", function()
    close(form)
  end)

  -- Clicking or otherwise landing on a non-field line should not leave the
  -- cursor somewhere that <CR> does nothing.
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = form.buf,
    callback = function()
      if not (form.win and vim.api.nvim_win_is_valid(form.win)) then
        return
      end
      local lnum = vim.api.nvim_win_get_cursor(form.win)[1]
      local index = form.field_of[lnum]
      if index then
        form.cursor = index
      end
    end,
  })

  render(form)
  return form
end

return M
