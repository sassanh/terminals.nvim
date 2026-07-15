---@class ActivateTerminalOptions
---@field id? integer
---@field toggle? boolean
---@field append_mode? boolean
---@field args? string[]

---@class Terminals
---@field terminal_window integer|nil
---@field border_window integer|nil
---@field terminal_state table<integer,boolean>
---@field last_terminal integer|nil
local M = {}

M.terminal_window = nil
M.border_window = nil
M.terminal_state = {}
M.last_terminal = 1
M.switching_terminals = false

local MIN_WINDOW_WIDTH = 26
local CHROME_HEIGHT = 4

local function default_width()
  return vim.fn.float2nr(vim.o.columns - math.max(((vim.o.columns - 105) * 3 / 10), 0))
end

local function default_height()
  return vim.o.lines - 1
end

---@param value number|string|nil
---@param total number
---@param fallback fun(): number
---@return number
local function resolve_dimension(value, total, fallback)
  if value == nil then
    return fallback()
  end
  if type(value) == "string" then
    local pct = value:match("^(%d+)%%$")
    if pct then
      return vim.fn.float2nr(total * tonumber(pct) / 100)
    end
  end
  if type(value) == "number" then
    return vim.fn.float2nr(value)
  end
  return fallback()
end

---@param value number|string|nil
---@param total number
---@param window_size number
---@param fallback fun(): number
---@return number
local function resolve_position(value, total, window_size, fallback)
  if value == nil then
    return fallback()
  end
  if type(value) == "string" then
    if value == "center" then
      return vim.fn.float2nr((total - window_size) / 2)
    end
    if value == "right" or value == "bottom" then
      return vim.fn.float2nr(total - window_size)
    end
    local pct = value:match("^(%d+)%%$")
    if pct then
      return vim.fn.float2nr(total * tonumber(pct) / 100)
    end
  end
  if type(value) == "number" then
    return vim.fn.float2nr(value)
  end
  return fallback()
end

---@param value number
---@param total number
---@param window_size number
---@return number
local function clamp_position(value, total, window_size)
  return math.max(0, math.min(value, total - window_size))
end

---@param tab_padding integer
---@return integer
local function tab_bar_width(tab_padding)
  return 1 + 10 * (tab_padding * 2 + 4)
end

---@param available_width number
---@return integer
local function choose_tab_padding(available_width)
  local padding = 3
  while padding > 0 and tab_bar_width(padding) > available_width do
    padding = padding - 1
  end
  return padding
end

---@param id integer
---@param tab_padding integer
---@return string, string, string
local function build_tab_headers(id, tab_padding)
  local header1 = "╭"
  local header2 = "┤"
  local header3 = "╰"
  local pad = (" "):rep(tab_padding)
  local dashes = ("─"):rep(tab_padding * 2 + 3)
  for i = 1, 10 do
    header1 = header1 .. dashes
    header2 = header2 .. pad .. ((i % 10) == id and "[" .. (i % 10) .. "]" or " " .. (i % 10) .. " ") .. pad
    header3 = header3 .. dashes
    header1 = header1 .. (i < 10 and "┬" or "╮")
    header2 = header2 .. (i < 10 and "│" or "├")
    header3 = header3 .. (i < 10 and "┴" or "╯")
  end
  return header1, header2, header3
end

---@param header1 string
---@param header2 string
---@param header3 string
---@param available_width number
---@param id integer
---@param margin boolean
---@return string, string, string
local function truncate_tab_headers(header1, header2, header3, available_width, id, margin)
  if vim.fn.strcharlen(header1) <= available_width then
    return header1, header2, header3
  end
  local margin_trim = margin and 4 or 0
  if id <= 5 and id ~= 0 then
    header1 = vim.fn.strcharpart(header1, 0, available_width - 1 - margin_trim) .. "─"
    header2 = vim.fn.strcharpart(header2, 0, available_width - 1 - margin_trim) .. " "
    header3 = vim.fn.strcharpart(header3, 0, available_width - 1 - margin_trim) .. "─"
  else
    local length = vim.fn.strcharlen(header1)
    header1 = "─" .. vim.fn.strcharpart(header1, length - available_width + 1 + margin_trim, length)
    header2 = " " .. vim.fn.strcharpart(header2, length - available_width + 1 + margin_trim, length)
    header3 = "─" .. vim.fn.strcharpart(header3, length - available_width + 1 + margin_trim, length)
  end
  return header1, header2, header3
end

---@param width_config number|string|nil
---@param height_config number|string|nil
---@param row_config number|string|nil
---@param col_config number|string|nil
---@param id integer
---@return table
function M.compute_window_layout(width_config, height_config, row_config, col_config, id)
  local margin = vim.o.columns > 102
  local width = resolve_dimension(width_config, vim.o.columns, default_width)
  local height = resolve_dimension(height_config, vim.o.lines, default_height)

  width = math.max(width, MIN_WINDOW_WIDTH)
  height = math.max(height, CHROME_HEIGHT)

  local col = resolve_position(col_config, vim.o.columns, width, function()
    return vim.fn.float2nr((vim.o.columns - width) / 2)
  end)
  local row = resolve_position(row_config, vim.o.lines, height, function()
    return 0
  end)
  col = clamp_position(col, vim.o.columns, width)
  row = clamp_position(row, vim.o.lines, height)

  local available_tab_width = width - (margin and 2 or 0)
  local tab_padding = choose_tab_padding(available_tab_width)
  local header1, header2, header3 = build_tab_headers(id, tab_padding)
  header1, header2, header3 = truncate_tab_headers(header1, header2, header3, available_tab_width, id, margin)

  return {
    width = width,
    height = height,
    row = row,
    col = col,
    margin = margin,
    tab_padding = tab_padding,
    terminal_height = height - CHROME_HEIGHT,
    header1 = header1,
    header2 = header2,
    header3 = header3,
    tab_bar_width = tab_bar_width(tab_padding),
  }
end

---@param direction 1|-1
function M.navigate(direction)
  if M.terminal_window ~= nil and vim.api.nvim_win_is_valid(M.terminal_window) then
    local next_terminal = (tonumber(vim.fn.bufname():gsub("^term://Terminal%-", ""), 10) + direction + 10) % 10
    M.activate_terminal({ id = next_terminal })
  elseif direction == 1 then
    vim.cmd.tabnext()
  elseif direction == -1 then
    vim.cmd.tabprevious()
  end
end

---@param direction 1|-1
function M.move_terminal(direction)
  if M.terminal_window ~= nil and vim.api.nvim_win_is_valid(M.terminal_window) then
    local current = tonumber(vim.fn.bufname():gsub("^term://Terminal%-", ""), 10)
    local other = (current + direction + 10) % 10
    local n1 = "term://Terminal-" .. current
    local n2 = "term://Terminal-" .. other
    local t1 = vim.fn.bufnr(n1)
    local t2 = vim.fn.bufnr(n2)
    if t1 ~= -1 then
      vim.api.nvim_buf_set_name(t1, "term://Terminal-Temporary")
      local old_buffer = vim.fn.bufnr(n1)
      if old_buffer then
        vim.api.nvim_buf_delete(old_buffer, { force = true })
      end
    end
    if t2 ~= -1 then
      vim.api.nvim_buf_set_name(t2, n1)
    end
    if t1 ~= -1 then
      vim.api.nvim_buf_set_name(t1, n2)
      local old_buffer = vim.fn.bufnr("term://Terminal-Temporary")
      if old_buffer then
        vim.api.nvim_buf_delete(old_buffer, { force = true })
      end
    end
    M.activate_terminal({ id = other, toggle = false })
  elseif direction == 1 then
    vim.cmd.tabmove("+")
  elseif direction == -1 then
    vim.cmd.tabmove("-")
  end
end

function M.enter_terminal()
  local config = require("terminals").config
  for char = 1, 126 do
    pcall(vim.keymap.del, { "t", ("<d-char-%s>"):format(char) })
    vim.keymap.set(
      "t",
      ("<d-char-%s>"):format(char),
      ("<char-24><char-64>s<char-%s>"):format(char),
      { noremap = true, buffer = true }
    )
  end
  vim.keymap.set("t", ("<%s-s-i>"):format(config.keys.modifier), function()
    M.leave_terminal()
    vim.cmd.startinsert()
  end, { buffer = true })
end

function M.leave_terminal()
  local config = require("terminals").config

  for char = 1, 126 do
    pcall(vim.keymap.del, { "t", ("<d-char-%s>"):format(char) })
  end
  for key, value in ipairs(config.preserved_keys) do
    if type(key) == "string" then
      vim.keymap.set("t", key, ("<c-\\><c-n>%s"):format(value), { buffer = true, silent = true })
    else
      vim.keymap.set("t", value, ("<c-\\><c-n>%s"):format(value), { buffer = true, silent = true })
    end
  end

  vim.keymap.set("t", config.keys.focus, function()
    M.enter_terminal()
    vim.cmd.startinsert()
  end, { buffer = true, silent = true })

  vim.keymap.set("t", config.keys.paste, "<c-\\><c-n>pa", { buffer = true })
  vim.keymap.set("t", config.keys.paste_in_place, "<c-\\><c-n>Pa", { buffer = true })

  vim.keymap.set("t", config.keys.go_left, function()
    M.save_terminal_state(true)
    M.navigate(-1)
  end, { buffer = true, silent = true })
  vim.keymap.set("t", config.keys.go_right, function()
    M.save_terminal_state(true)
    M.navigate(1)
  end, { buffer = true, silent = true })
  vim.keymap.set("t", config.keys.move_left, function()
    M.move_terminal(-1)
  end, { buffer = true, silent = true })
  vim.keymap.set("t", config.keys.move_right, function()
    M.move_terminal(1)
  end, { buffer = true, silent = true })
  for i = 0, 9 do
    vim.keymap.set("t", ("<%s-%s>"):format(config.keys.modifier, i), function()
      M.save_terminal_state(true)
      M.activate_terminal({ id = i })
    end, { buffer = true, silent = true })
  end
  vim.keymap.set("t", config.keys.toggle, function()
    M.save_terminal_state(true)
    M.toggle_terminal()
  end, { buffer = true, silent = true })
  vim.keymap.set("t", config.keys.toggle_reverse_search, "<c-\\><c-n>?", { buffer = true })
  vim.keymap.set("t", config.keys.leave, "<c-\\><c-n>", { buffer = true, silent = true })
end

--- @param opts ActivateTerminalOptions|nil
function M.activate_terminal(opts)
  opts = opts or {}
  local id = 1
  local toggle = opts["toggle"] == nil or opts["toggle"]
  local append_mode = opts["append_mode"] == nil or opts["append_mode"]
  if opts["id"] ~= nil then
    id = opts["id"]
    if M.terminal_window ~= nil and vim.api.nvim_win_is_valid(M.terminal_window) then
      local current = tonumber(vim.fn.bufname():gsub("^term://Terminal%-", ""), 10)
      if current == id and toggle then
        M.toggle_terminal()
        return
      end
    end
  end
  local creation_args = nil
  if opts["args"] ~= "" and opts["args"] ~= nil then
    creation_args = opts["args"]
  end
  local buffer_name = "term://Terminal-" .. id
  local should_create = true
  local buffer

  local config = require("terminals").config
  local layout = M.compute_window_layout(config.width, config.height, config.row, config.col, id)
  local width = layout.width
  local height = layout.height
  local row = layout.row
  local col = layout.col
  local margin = layout.margin
  local header1 = layout.header1
  local header2 = layout.header2
  local header3 = layout.header3

  local bufnr = vim.fn.bufnr(buffer_name)
  if bufnr ~= -1 then
    if vim.api.nvim_get_option_value("buftype", { buf = bufnr }) == "terminal" then
      should_create = false
      buffer = bufnr
    else
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end

  M.switching_terminals = true

  local win_opts = {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    border = "none",
  }
  local border_buffer
  if M.border_window ~= nil and vim.api.nvim_win_is_valid(M.border_window) then
    vim.api.nvim_win_set_config(M.border_window, win_opts)
    border_buffer = vim.api.nvim_win_get_buf(M.border_window)
  else
    border_buffer = vim.api.nvim_create_buf(false, true)
    M.border_window = vim.api.nvim_open_win(border_buffer, true, win_opts)
    vim.api.nvim_set_option_value("cursorline", false, { win = M.border_window })
    vim.api.nvim_set_option_value("number", false, { win = M.border_window })
    vim.api.nvim_set_option_value("relativenumber", false, { win = M.border_window })
    vim.api.nvim_set_option_value("signcolumn", "no", { win = M.border_window })
    vim.api.nvim_set_option_value("winhighlight", "Normal:WindowBorder", { win = M.border_window })
  end
  local l1 = (width - (margin and 2 or 0) - vim.fn.strcharlen(header1)) / 2
  local l2 = (width - (margin and 2 or 0) - vim.fn.strcharlen(header1)) / 2
    + ((width - 2 - vim.fn.strcharlen(header1)) % 2)
  if margin then
    vim.api.nvim_buf_set_lines(border_buffer, 0, -1, true, { (" "):rep(l1 + 1) .. header1 .. (" "):rep(l2 + 1) })
    vim.api.nvim_buf_set_lines(
      border_buffer,
      -1,
      -1,
      true,
      { "╭" .. ("─"):rep(l1) .. header2 .. ("─"):rep(l2) .. "╮" }
    )
    vim.api.nvim_buf_set_lines(
      border_buffer,
      -1,
      -1,
      true,
      { "│" .. (" "):rep(l1) .. header3 .. (" "):rep(l2) .. "│" }
    )
    for _ = 1, height - 4 do
      vim.api.nvim_buf_set_lines(border_buffer, -1, -1, true, { "│" .. (" "):rep(width - 2) .. "│" })
    end
    vim.api.nvim_buf_set_lines(border_buffer, -1, -1, true, { "╰" .. ("─"):rep(width - 2) .. "╯" })
  else
    vim.api.nvim_buf_set_lines(border_buffer, 0, -1, true, { (" "):rep(l1) .. header1 .. (" "):rep(l2) })
    vim.api.nvim_buf_set_lines(border_buffer, -1, -1, true, { ("─"):rep(l1) .. header2 .. ("─"):rep(l2) })
    vim.api.nvim_buf_set_lines(border_buffer, -1, -1, true, { (" "):rep(l1) .. header3 .. (" "):rep(l2) })
    for _ = 1, height - 4 do
      vim.api.nvim_buf_set_lines(border_buffer, -1, -1, true, { " " })
    end
    vim.api.nvim_buf_set_lines(border_buffer, -1, -1, true, { ("─"):rep(width) })
  end

  win_opts = {
    relative = "editor",
    row = row + 3,
    col = col + (margin and 1 or 0),
    width = width - (margin and 2 or 0),
    height = layout.terminal_height,
    border = "",
  }

  if should_create then
    if M.terminal_window ~= nil and vim.api.nvim_win_is_valid(M.terminal_window) then
      vim.api.nvim_win_set_config(M.terminal_window, win_opts)
      vim.api.nvim_set_current_win(M.terminal_window)
    else
      M.terminal_window = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, win_opts)
    end
  elseif M.terminal_window ~= nil and vim.api.nvim_win_is_valid(M.terminal_window) then
    vim.api.nvim_win_set_config(M.terminal_window, win_opts)
    vim.api.nvim_win_set_buf(M.terminal_window, buffer)
    vim.api.nvim_set_current_win(M.terminal_window)
  else
    M.terminal_window = vim.api.nvim_open_win(buffer, true, win_opts)
  end

  vim.api.nvim_set_option_value("number", false, { win = M.terminal_window })
  vim.api.nvim_set_option_value("relativenumber", false, { win = M.terminal_window })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = M.terminal_window })
  vim.api.nvim_set_option_value("winhighlight", "Normal:WindowBorder", { win = M.terminal_window })

  if should_create then
    local shell = require("terminals").config.shell
    if creation_args then
      vim.cmd.terminal(creation_args)
    elseif shell then
      vim.cmd.terminal(shell)
    else
      vim.cmd.terminal()
    end
    buffer = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(buffer, buffer_name)
    M.terminal_state[buffer] = true
  end

  vim.api.nvim_set_current_win(M.terminal_window)
  if M.terminal_state[buffer] then
    if append_mode then
      vim.cmd.startinsert()
    else
      M.toggle_terminal()
    end
  end

  M.switching_terminals = false
end

function M.close_terminal()
  if M.terminal_window ~= nil and vim.api.nvim_win_is_valid(M.terminal_window) then
    vim.api.nvim_win_close(M.terminal_window, false)
  end
  if M.border_window ~= nil and vim.api.nvim_win_is_valid(M.border_window) then
    vim.api.nvim_win_close(M.border_window, false)
  end
end

function M.toggle_terminal(append_mode)
  append_mode = append_mode == nil or append_mode
  if M.terminal_window ~= nil and vim.api.nvim_win_is_valid(M.terminal_window) then
    vim.api.nvim_win_close(M.terminal_window, false)
    if M.border_window ~= nil and vim.api.nvim_win_is_valid(M.border_window) then
      vim.api.nvim_win_close(M.border_window, false)
    end
  else
    M.activate_terminal({ id = M.last_terminal, toggle = true, append_mode = append_mode })
  end
end

---@param name string
function M.terminal_window_closed(name)
  if M.switching_terminals then
    return
  end
  if vim.startswith(name, "term://Terminal-") then
    if M.terminal_window ~= nil and vim.api.nvim_win_is_valid(M.terminal_window) then
      vim.api.nvim_win_close(M.terminal_window, false)
      if M.border_window ~= nil and vim.api.nvim_win_is_valid(M.border_window) then
        vim.api.nvim_win_close(M.border_window, false)
      end
    end
  end
end

---@param state boolean
function M.save_terminal_state(state)
  M.terminal_state[vim.fn.bufnr()] = state
  local bufname = vim.fn.bufname()
  if bufname ~= nil and vim.startswith(bufname, "term://Terminal-") then
    M.last_terminal = tonumber(vim.fn.bufname():gsub("^term://Terminal%-", ""), 10)
  end
end

function M.handle_resize()
  if M.terminal_window ~= nil and vim.api.nvim_win_is_valid(M.terminal_window) then
    M.save_terminal_state(false)
    M.toggle_terminal()
    M.toggle_terminal(false)
  end
end

return M
