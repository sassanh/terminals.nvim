---@class ActivateTerminalOptions
---@field id? integer
---@field toggle? boolean
---@field append_mode? boolean
---@field relayout? boolean
---@field args? string[]

---@class Terminals
---@field terminal_window integer|nil
---@field border_window integer|nil
---@field terminal_state table<integer,boolean>
---@field last_terminal integer|nil
---@field current_layout table|nil
local M = {}

M.terminal_window = nil
M.border_window = nil
M.terminal_state = {}
M.last_terminal = 1
M.current_layout = nil
M.layout_index = 1
M.switching_terminals = false
M._mouse_press_tab_id = nil
M._drag_preview = nil
M.tab_scroll_cooldown_ms = 150
M._last_tab_scroll_ms = nil

local MIN_WINDOW_WIDTH = 26
local CHROME_HEIGHT = 4
local TAB_BAR_HEIGHT = 3
local DRAG_PREVIEW_NS = vim.api.nvim_create_namespace("terminals_tab_drag")
local SWAP_FLASH_NS = vim.api.nvim_create_namespace("terminals_tab_swap")
local SWAP_FLASH_MS = 400
local swap_flash_timer = nil

function M.default_width()
  return vim.fn.float2nr(vim.o.columns - math.max(((vim.o.columns - 105) * 3 / 10), 0))
end

function M.default_height()
  return vim.o.lines - 1
end

---@alias LayoutValue number|string|fun(): number

---@param value LayoutValue|nil
---@param total number
---@param fallback fun(): number
---@return number
local function resolve_dimension(value, total, fallback)
  if value == nil then
    return fallback()
  end
  if type(value) == "function" then
    return vim.fn.float2nr(value())
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

---@alias PositionValue number|string|fun(): number

---@param value PositionValue|nil
---@param total number
---@param window_size number
---@param fallback fun(): number
---@return number
local function resolve_position(value, total, window_size, fallback)
  if value == nil then
    return fallback()
  end
  if type(value) == "function" then
    return vim.fn.float2nr(value())
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

---@return number|string|nil, number|string|nil, number|string|nil, number|string|nil
function M.resolve_active_layout()
  local config = require("terminals").config
  local preset = config.layouts and config.layouts[M.layout_index]
  if preset then
    return preset.width or config.width,
      preset.height or config.height,
      preset.row or config.row,
      preset.col or config.col
  end
  return config.width, config.height, config.row, config.col
end

function M.cycle_layout()
  local config = require("terminals").config
  local layouts = config.layouts
  if not layouts or #layouts == 0 then
    return
  end
  M.layout_index = (M.layout_index % #layouts) + 1
  if M.terminal_window == nil or not vim.api.nvim_win_is_valid(M.terminal_window) then
    return
  end
  local buffer = vim.api.nvim_win_get_buf(M.terminal_window)
  local bufname = vim.api.nvim_buf_get_name(buffer)
  local id = tonumber(bufname:gsub("^term://Terminal%-", ""), 10) or M.last_terminal
  local append_mode = M.terminal_state[buffer] == true
  M.activate_terminal({
    id = id,
    toggle = false,
    append_mode = append_mode,
    relayout = true,
  })
end

---@param width_config number|string|nil
---@param height_config number|string|nil
---@param row_config number|string|nil
---@param col_config number|string|nil
---@param id integer
---@return table
function M.compute_window_layout(width_config, height_config, row_config, col_config, id)
  local margin = vim.o.columns > 102
  local width = resolve_dimension(width_config, vim.o.columns, M.default_width)
  local height = resolve_dimension(height_config, vim.o.lines, M.default_height)

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

  local header_length = vim.fn.strcharlen(header1)
  local total_header_pad = width - (margin and 2 or 0) - header_length
  local header_left_pad = vim.fn.float2nr(total_header_pad / 2)
  local header_right_pad = total_header_pad - header_left_pad

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
    header_left_pad = header_left_pad,
    header_right_pad = header_right_pad,
  }
end

---@param header2 string truncated tab header line
---@param tab_padding integer per-tab padding used to build the header
---@param relative_index integer 0-indexed character index within header2
---@return integer|nil tab id (0-9) or nil when the index is not on a tab
function M.tab_id_at_header_index(header2, tab_padding, relative_index)
  if type(header2) ~= "string" then
    return nil
  end
  if type(tab_padding) ~= "number" or type(relative_index) ~= "number" then
    return nil
  end
  local cell_width = tab_padding * 2 + 4
  local full_width = 1 + 10 * cell_width
  local truncated_length = vim.fn.strcharlen(header2)
  if relative_index < 0 or relative_index >= truncated_length then
    return nil
  end
  local is_truncated = truncated_length < full_width
  local starts_with_border = vim.fn.strcharpart(header2, 0, 1) == "┤"
  local start_index = 0
  if is_truncated and not starts_with_border then
    start_index = full_width - truncated_length + 1
  end
  if start_index > 0 and relative_index == 0 then
    return nil
  end
  if start_index == 0 and is_truncated and relative_index == truncated_length - 1 then
    if vim.fn.strcharpart(header2, truncated_length - 1, 1) == " " then
      return nil
    end
  end
  local original_index
  if start_index == 0 then
    original_index = relative_index
  else
    original_index = start_index + relative_index - 1
  end
  if original_index <= 0 or original_index >= full_width then
    return nil
  end
  local cell = math.floor((original_index - 1) / cell_width)
  if cell < 0 or cell > 9 then
    return nil
  end
  return (cell + 1) % 10
end

---@param click_line integer 1-indexed buffer line in the border window
---@param click_wincol integer 1-indexed window column of the click
---@param layout table layout returned by compute_window_layout
---@return integer|nil tab id (0-9) or nil when the click is not on a tab
function M.tab_id_for_border_click(click_line, click_wincol, layout)
  if type(click_line) ~= "number" or type(click_wincol) ~= "number" then
    return nil
  end
  if click_line < 1 or click_line > TAB_BAR_HEIGHT then
    return nil
  end
  if layout == nil then
    return nil
  end
  local header2 = layout.header2
  local tab_padding = layout.tab_padding
  local left_pad = layout.header_left_pad
  if type(header2) ~= "string" or type(tab_padding) ~= "number" or type(left_pad) ~= "number" then
    return nil
  end
  local header_start = left_pad + (layout.margin and 1 or 0)
  local relative_index = (click_wincol - 1) - header_start
  return M.tab_id_at_header_index(header2, tab_padding, relative_index)
end

function M.handle_tab_click()
  local id = M.border_tab_under_mouse()
  if id == nil then
    return false
  end
  M.activate_terminal({ id = id, toggle = false })
  return true
end

function M.handle_mouse_click()
  return M.handle_tab_click()
end

function M._handle_mouse_pressed()
  local id = M.border_tab_under_mouse()
  if id ~= nil then
    M._mouse_press_tab_id = id
    M._clear_drag_preview()
    vim.schedule(function()
      M.activate_terminal({ id = id, toggle = false })
      if M._mouse_press_tab_id == id then
        M._show_drag_preview(id, id)
      end
    end)
    return
  end
  M._mouse_press_tab_id = nil
  M._clear_drag_preview()
  local mouse = vim.fn.getmousepos()
  if mouse.winid == 0 then
    return
  end
  vim.api.nvim_input_mouse("left", "press", "", 0, mouse.screenrow - 1, mouse.screencol - 1)
end

function M._handle_mouse_dragged()
  local press_id = M._mouse_press_tab_id
  if press_id == nil then
    local mouse = vim.fn.getmousepos()
    if mouse.winid == 0 then
      return
    end
    vim.api.nvim_input_mouse("left", "drag", "", 0, mouse.screenrow - 1, mouse.screencol - 1)
    return
  end
  local id = M.border_tab_under_mouse()
  if id == nil then
    M._show_drag_preview(press_id, nil)
    return
  end
  M._show_drag_preview(press_id, id)
end

function M._handle_mouse_released()
  local press_id = M._mouse_press_tab_id
  if press_id ~= nil then
    local release_id = M.border_tab_under_mouse()
    M._mouse_press_tab_id = nil
    if release_id ~= nil and release_id ~= press_id then
      M._clear_drag_preview()
      M.swap_terminals(press_id, release_id)
      return
    end
    M._clear_drag_preview()
    return
  end
  M._clear_drag_preview()
  local mouse = vim.fn.getmousepos()
  if mouse.winid == 0 then
    return
  end
  vim.api.nvim_input_mouse("left", "release", "", 0, mouse.screenrow - 1, mouse.screencol - 1)
end

function M._mouse_click_expr(lhs)
  local id = M.border_tab_under_mouse()
  if id == nil then
    return vim.api.nvim_replace_termcodes(lhs, true, true, true)
  end
  M.activate_terminal({ id = id, toggle = false })
  return ""
end

function M._save_current_terminal_state()
  if M.terminal_window == nil or not vim.api.nvim_win_is_valid(M.terminal_window) then
    return
  end
  local current_window = vim.api.nvim_get_current_win()
  if current_window ~= M.terminal_window then
    return
  end
  local mode = vim.api.nvim_get_mode().mode
  local is_insert = mode == "t"
  local buffer = vim.api.nvim_win_get_buf(M.terminal_window)
  M.terminal_state[buffer] = is_insert
end

---@param mouse table mouse position returned by vim.fn.getmousepos()
---@param border_window integer|nil border window id
---@return boolean true when the mouse is over the tab-bar rows of the border window
local function mouse_on_tab_bar(mouse, border_window)
  if mouse == nil or mouse.winid == 0 then
    return false
  end
  if border_window == nil or not vim.api.nvim_win_is_valid(border_window) then
    return false
  end
  if mouse.winid ~= border_window then
    return false
  end
  return mouse.line >= 1 and mouse.line <= TAB_BAR_HEIGHT
end

---@return boolean true when the mouse is over the tab-bar rows of the border window
function M.is_mouse_on_tab_bar()
  if M.current_layout == nil then
    return false
  end
  return mouse_on_tab_bar(vim.fn.getmousepos(), M.border_window)
end

---@return integer|nil tab id under the mouse when the mouse is on a border tab
function M.border_tab_under_mouse()
  local layout = M.current_layout
  if layout == nil then
    return nil
  end
  local mouse = vim.fn.getmousepos()
  if not mouse_on_tab_bar(mouse, M.border_window) then
    return nil
  end
  return M.tab_id_for_border_click(mouse.line, mouse.wincol, layout)
end

---@param layout table layout returned by compute_window_layout
---@param tab_id integer tab id (0-9)
---@return integer|nil start 0-indexed inclusive character index in header2, integer|nil end_exclusive character index
function M._tab_cell_char_range(layout, tab_id)
  if layout == nil or type(tab_id) ~= "number" then
    return nil
  end
  local header2 = layout.header2
  local tab_padding = layout.tab_padding
  if type(header2) ~= "string" or type(tab_padding) ~= "number" then
    return nil
  end
  local length = vim.fn.strcharlen(header2)
  local first = nil
  local last = nil
  for index = 0, length - 1 do
    if M.tab_id_at_header_index(header2, tab_padding, index) == tab_id then
      if first == nil then
        first = index
      end
      last = index
    end
  end
  if first == nil or last == nil then
    return nil
  end
  return first, last + 1
end

local function ensure_drag_highlights()
  vim.api.nvim_set_hl(0, "TerminalsTabDragSource", { link = "Visual", default = true })
  vim.api.nvim_set_hl(0, "TerminalsTabDragDest", { link = "Search", default = true })
end

---@param buffer integer border buffer id
---@param layout table layout returned by compute_window_layout
---@param tab_id integer tab id (0-9)
---@param highlight string highlight group name
---@param namespace integer namespace id for the extmark
local function highlight_tab_cell(buffer, layout, tab_id, highlight, namespace)
  local start_char, end_char = M._tab_cell_char_range(layout, tab_id)
  if start_char == nil or end_char == nil then
    return
  end
  local header2 = layout.header2
  if type(header2) == "string" then
    local separators = { ["│"] = true, ["├"] = true, ["┤"] = true }
    if separators[vim.fn.strcharpart(header2, start_char, 1)] then
      start_char = start_char + 1
    end
    if end_char > start_char and separators[vim.fn.strcharpart(header2, end_char - 1, 1)] then
      end_char = end_char - 1
    end
  end
  if end_char <= start_char then
    return
  end
  local header_offset = layout.header_left_pad + (layout.margin and 1 or 0)
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buffer, 1, 2, false)
  if not ok or type(lines) ~= "table" then
    return
  end
  local line = lines[1]
  if type(line) ~= "string" then
    return
  end
  local start_byte = vim.fn.byteidx(line, header_offset + start_char)
  local end_byte = vim.fn.byteidx(line, header_offset + end_char)
  if start_byte >= 0 and end_byte >= 0 and end_byte > start_byte then
    pcall(vim.api.nvim_buf_set_extmark, buffer, namespace, 1, start_byte, {
      end_row = 1,
      end_col = end_byte,
      hl_group = highlight,
    })
  end
end

function M._clear_swap_flash()
  if swap_flash_timer ~= nil then
    pcall(function()
      swap_flash_timer:stop()
      swap_flash_timer:close()
    end)
    swap_flash_timer = nil
  end
  if M.border_window == nil or not vim.api.nvim_win_is_valid(M.border_window) then
    return
  end
  local ok, buffer = pcall(vim.api.nvim_win_get_buf, M.border_window)
  if not ok or buffer == nil then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, buffer, SWAP_FLASH_NS, 0, -1)
end

---@param first integer first swapped slot (0-9)
---@param second integer second swapped slot (0-9)
---@param duration_ms integer|nil flash duration, defaults to SWAP_FLASH_MS (used by tests)
function M._flash_swap_tabs(first, second, duration_ms)
  if M.border_window == nil or not vim.api.nvim_win_is_valid(M.border_window) then
    return
  end
  local layout = M.current_layout
  if layout == nil then
    return
  end
  local ok, buffer = pcall(vim.api.nvim_win_get_buf, M.border_window)
  if not ok or buffer == nil then
    return
  end
  M._clear_swap_flash()
  ensure_drag_highlights()
  highlight_tab_cell(buffer, layout, first, "TerminalsTabDragDest", SWAP_FLASH_NS)
  highlight_tab_cell(buffer, layout, second, "TerminalsTabDragDest", SWAP_FLASH_NS)
  local timeout = duration_ms or SWAP_FLASH_MS
  local timer = vim.defer_fn(function()
    swap_flash_timer = nil
    if M.border_window == nil or not vim.api.nvim_win_is_valid(M.border_window) then
      return
    end
    local buffer_ok, live_buffer = pcall(vim.api.nvim_win_get_buf, M.border_window)
    if not buffer_ok or live_buffer ~= buffer then
      return
    end
    pcall(vim.api.nvim_buf_clear_namespace, buffer, SWAP_FLASH_NS, 0, -1)
  end, timeout)
  swap_flash_timer = timer
end

function M._clear_drag_preview()
  M._drag_preview = nil
  if M.border_window == nil or not vim.api.nvim_win_is_valid(M.border_window) then
    return
  end
  local ok, buffer = pcall(vim.api.nvim_win_get_buf, M.border_window)
  if not ok or buffer == nil then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, buffer, DRAG_PREVIEW_NS, 0, -1)
end

---@param source_id integer press tab id
---@param dest_id integer|nil hovered tab id, nil when off the tab bar
function M._show_drag_preview(source_id, dest_id)
  local layout = M.current_layout
  if layout == nil then
    return
  end
  if M.border_window == nil or not vim.api.nvim_win_is_valid(M.border_window) then
    return
  end
  local ok, buffer = pcall(vim.api.nvim_win_get_buf, M.border_window)
  if not ok or buffer == nil then
    return
  end
  local current = M._drag_preview
  if current ~= nil and current.source == source_id and current.dest == dest_id then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, buffer, DRAG_PREVIEW_NS, 0, -1)
  ensure_drag_highlights()
  if dest_id == nil then
    highlight_tab_cell(buffer, layout, source_id, "TerminalsTabDragSource", DRAG_PREVIEW_NS)
  elseif dest_id == source_id then
    highlight_tab_cell(buffer, layout, source_id, "TerminalsTabDragDest", DRAG_PREVIEW_NS)
  else
    highlight_tab_cell(buffer, layout, source_id, "TerminalsTabDragSource", DRAG_PREVIEW_NS)
    highlight_tab_cell(buffer, layout, dest_id, "TerminalsTabDragDest", DRAG_PREVIEW_NS)
  end
  M._drag_preview = { source = source_id, dest = dest_id }
end

---@return number current monotonic time in milliseconds
function M._now_ms()
  if vim.uv ~= nil and vim.uv.hrtime ~= nil then
    return vim.uv.hrtime() / 1e6
  end
  if vim.loop ~= nil and vim.loop.hrtime ~= nil then
    return vim.loop.hrtime() / 1e6
  end
  return vim.fn.reltimefloat(vim.fn.reltime()) * 1000
end

---@param direction 1|-1
---@param now_ms number|nil override for the current time (used by tests)
---@return boolean true when the scroll was over the tab bar and swallowed
function M.handle_tab_scroll(direction, now_ms)
  if not M.is_mouse_on_tab_bar() then
    return false
  end
  local now = now_ms or M._now_ms()
  if M._last_tab_scroll_ms ~= nil and now - M._last_tab_scroll_ms < M.tab_scroll_cooldown_ms then
    return true
  end
  M._last_tab_scroll_ms = now
  M.navigate(direction)
  return true
end

---@param wheel_action string one of "up", "down", "left", "right"
---@param direction 1|-1 navigation direction matching the wheel action
function M._handle_scroll(wheel_action, direction)
  if M.handle_tab_scroll(direction) then
    return
  end
  local mouse = vim.fn.getmousepos()
  if mouse.winid == 0 then
    return
  end
  vim.api.nvim_input_mouse("wheel", wheel_action, "", 0, mouse.screenrow - 1, mouse.screencol - 1)
end

function M.on_win_enter()
  if M.switching_terminals then
    return
  end
  if M.border_window == nil or not vim.api.nvim_win_is_valid(M.border_window) then
    return
  end
  local ok, current_window = pcall(vim.api.nvim_get_current_win)
  if not ok or current_window ~= M.border_window then
    return
  end
  M.handle_tab_click()
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

---@param first integer first terminal slot (0-9)
---@param second integer second terminal slot (0-9)
function M.swap_terminals(first, second)
  if type(first) ~= "number" or type(second) ~= "number" then
    return
  end
  if first == second then
    return
  end
  if M.terminal_window == nil or not vim.api.nvim_win_is_valid(M.terminal_window) then
    return
  end
  local n1 = "term://Terminal-" .. first
  local n2 = "term://Terminal-" .. second
  local t1 = vim.fn.bufnr(n1)
  local t2 = vim.fn.bufnr(n2)
  if t1 == -1 and t2 == -1 then
    M.activate_terminal({ id = second, toggle = false })
    return
  end
  local function delete_leftover(name)
    local leftover = vim.fn.bufnr(name)
    if leftover ~= -1 and leftover ~= t1 and leftover ~= t2 then
      vim.api.nvim_buf_delete(leftover, { force = true })
    end
  end
  if t1 ~= -1 then
    vim.api.nvim_buf_set_name(t1, "term://Terminal-Temporary")
    delete_leftover(n1)
  end
  if t2 ~= -1 then
    vim.api.nvim_buf_set_name(t2, n1)
    delete_leftover(n2)
  end
  if t1 ~= -1 then
    vim.api.nvim_buf_set_name(t1, n2)
    delete_leftover("term://Terminal-Temporary")
  end
  M.activate_terminal({ id = second, toggle = false })
  M._flash_swap_tabs(first, second)
end

---@param direction 1|-1
function M.move_terminal(direction)
  if M.terminal_window ~= nil and vim.api.nvim_win_is_valid(M.terminal_window) then
    local current = tonumber(vim.fn.bufname():gsub("^term://Terminal%-", ""), 10)
    local other = (current + direction + 10) % 10
    M.swap_terminals(current, other)
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
    M.navigate(-1)
  end, { buffer = true, silent = true })
  vim.keymap.set("t", config.keys.go_right, function()
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
      M.activate_terminal({ id = i })
    end, { buffer = true, silent = true })
  end
  vim.keymap.set("t", config.keys.toggle, function()
    M.toggle_terminal()
  end, { buffer = true, silent = true })
  vim.keymap.set("t", config.keys.cycle_layout, function()
    M.cycle_layout()
  end, { buffer = true, silent = true })
  vim.keymap.set("n", config.keys.cycle_layout, function()
    M.cycle_layout()
  end, { buffer = true, silent = true })
  vim.keymap.set("t", config.keys.toggle_reverse_search, "<c-\\><c-n>?", { buffer = true })
  vim.keymap.set("t", config.keys.leave, "<c-\\><c-n>", { buffer = true, silent = true })
  vim.keymap.set("t", "<LeftMouse>", function()
    M._handle_mouse_pressed()
  end, { buffer = true, silent = true })
  vim.keymap.set("t", "<LeftDrag>", function()
    M._handle_mouse_dragged()
  end, { buffer = true, silent = true })
  vim.keymap.set("t", "<LeftRelease>", function()
    M._handle_mouse_released()
  end, { buffer = true, silent = true })
  vim.keymap.set("n", "<LeftMouse>", function()
    M._handle_mouse_pressed()
  end, { buffer = true, silent = true })
  vim.keymap.set("n", "<LeftDrag>", function()
    M._handle_mouse_dragged()
  end, { buffer = true, silent = true })
  vim.keymap.set("n", "<LeftRelease>", function()
    M._handle_mouse_released()
  end, { buffer = true, silent = true })
  vim.keymap.set("t", "<ScrollWheelUp>", function()
    M._handle_scroll("up", -1)
  end, { buffer = true, silent = true })
  vim.keymap.set("t", "<ScrollWheelDown>", function()
    M._handle_scroll("down", 1)
  end, { buffer = true, silent = true })
  vim.keymap.set("t", "<ScrollWheelLeft>", function()
    M._handle_scroll("left", -1)
  end, { buffer = true, silent = true })
  vim.keymap.set("t", "<ScrollWheelRight>", function()
    M._handle_scroll("right", 1)
  end, { buffer = true, silent = true })
  vim.keymap.set("n", "<ScrollWheelUp>", function()
    M._handle_scroll("up", -1)
  end, { buffer = true, silent = true })
  vim.keymap.set("n", "<ScrollWheelDown>", function()
    M._handle_scroll("down", 1)
  end, { buffer = true, silent = true })
  vim.keymap.set("n", "<ScrollWheelLeft>", function()
    M._handle_scroll("left", -1)
  end, { buffer = true, silent = true })
  vim.keymap.set("n", "<ScrollWheelRight>", function()
    M._handle_scroll("right", 1)
  end, { buffer = true, silent = true })
end

--- @param opts ActivateTerminalOptions|nil
function M.activate_terminal(opts)
  M._save_current_terminal_state()
  opts = opts or {}
  local id = 1
  local toggle = opts["toggle"] == nil or opts["toggle"]
  local append_mode = opts["append_mode"] == nil or opts["append_mode"]
  if opts["id"] ~= nil then
    id = opts["id"]
  end
  M.last_terminal = id
  if opts["id"] ~= nil then
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

  local width_cfg, height_cfg, row_cfg, col_cfg = M.resolve_active_layout()
  local layout = M.compute_window_layout(width_cfg, height_cfg, row_cfg, col_cfg, id)
  M.current_layout = layout
  local width = layout.width
  local height = layout.height
  local row = layout.row
  local col = layout.col
  local margin = layout.margin
  local header1 = layout.header1
  local header2 = layout.header2
  local header3 = layout.header3
  local left_pad = layout.header_left_pad
  local right_pad = layout.header_right_pad

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
  local l1 = left_pad
  local l2 = right_pad
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
    elseif not opts.relayout then
      M.toggle_terminal()
    end
  end

  M.switching_terminals = false
end

function M.close_terminal()
  M.switching_terminals = true
  M._mouse_press_tab_id = nil
  M._drag_preview = nil
  M._clear_swap_flash()
  if M.terminal_window ~= nil and vim.api.nvim_win_is_valid(M.terminal_window) then
    vim.api.nvim_win_close(M.terminal_window, false)
  end
  if M.border_window ~= nil and vim.api.nvim_win_is_valid(M.border_window) then
    vim.api.nvim_win_close(M.border_window, false)
  end
  M.switching_terminals = false
end

function M.toggle_terminal(append_mode)
  append_mode = append_mode == nil or append_mode
  if M.terminal_window ~= nil and vim.api.nvim_win_is_valid(M.terminal_window) then
    M.close_terminal()
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
    if M.border_tab_under_mouse() ~= nil then
      return
    end
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
end

function M.handle_resize()
  if M.terminal_window ~= nil and vim.api.nvim_win_is_valid(M.terminal_window) then
    M.toggle_terminal()
    M.toggle_terminal(false)
  end
end

return M
