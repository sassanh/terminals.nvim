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

---Maps every character index of a full, untruncated tab header to the tab
---whose cell contains it. Index 0 is the leading border character and has no
---entry.
---@param tab_padding integer
---@return table<integer, integer>
local function build_tab_hit_map(tab_padding)
  local cell_width = tab_padding * 2 + 4
  local tab_id_by_char = {}
  for cell = 0, 9 do
    local first_index = 1 + cell * cell_width
    for offset = 0, cell_width - 1 do
      tab_id_by_char[first_index + offset] = (cell + 1) % 10
    end
  end
  return tab_id_by_char
end

---@param id integer primary bracketed tab id
---@param tab_padding integer
---@return string, string, string
local function build_tab_headers(id, tab_padding)
  local header1 = "╭"
  local header2 = "┤"
  local header3 = "╰"
  local pad = (" "):rep(tab_padding)
  local dashes = ("─"):rep(tab_padding * 2 + 3)
  for i = 1, 10 do
    local digit = i % 10
    header1 = header1 .. dashes
    header2 = header2 .. pad .. (digit == id and "[" .. digit .. "]" or " " .. digit .. " ") .. pad
    header3 = header3 .. dashes
    header1 = header1 .. (i < 10 and "┬" or "╮")
    header2 = header2 .. (i < 10 and "│" or "├")
    header3 = header3 .. (i < 10 and "┴" or "╯")
  end
  return header1, header2, header3
end

---Truncates the tab-bar rows for narrow windows, transforming the hit map
---with the same cut so positions keep resolving to their tabs.
---@param header1 string
---@param header2 string
---@param header3 string
---@param available_width number
---@param id integer
---@param margin boolean
---@param tab_id_by_char table<integer, integer> hit map of the untruncated header2
---@return string, string, string, table
local function truncate_tab_headers(header1, header2, header3, available_width, id, margin, tab_id_by_char)
  if vim.fn.strcharlen(header1) <= available_width then
    return header1, header2, header3, tab_id_by_char
  end
  local margin_trim = margin and 4 or 0
  local truncated = {}
  if id <= 5 and id ~= 0 then
    local keep = available_width - 1 - margin_trim
    header1 = vim.fn.strcharpart(header1, 0, keep) .. "─"
    header2 = vim.fn.strcharpart(header2, 0, keep) .. " "
    header3 = vim.fn.strcharpart(header3, 0, keep) .. "─"
    for index = 0, keep - 1 do
      truncated[index] = tab_id_by_char[index]
    end
  else
    local length = vim.fn.strcharlen(header1)
    local start = length - available_width + 1 + margin_trim
    header1 = "─" .. vim.fn.strcharpart(header1, start, length)
    header2 = " " .. vim.fn.strcharpart(header2, start, length)
    header3 = "─" .. vim.fn.strcharpart(header3, start, length)
    for index = start, length - 1 do
      truncated[index - start + 1] = tab_id_by_char[index]
    end
  end
  return header1, header2, header3, truncated
end

---@param layout table layout returned by compute_window_layout
---@param header2 string truncated header2 to embed
---@return string full border-buffer line for the tab-bar row
local function header2_border_line(layout, header2)
  local left_pad = layout.header_left_pad
  local right_pad = layout.header_right_pad
  if layout.margin then
    return "╭" .. ("─"):rep(left_pad) .. header2 .. ("─"):rep(right_pad) .. "╮"
  end
  return ("─"):rep(left_pad) .. header2 .. ("─"):rep(right_pad)
end

---Fills the border buffer with the tab bar and window frame from layout.
---@param buffer integer border buffer id
---@param layout TerminalLayout layout returned by compute_window_layout
local function render_border_buffer(buffer, layout)
  local width = layout.width
  local height = layout.height
  local header1 = layout.header1
  local header2 = layout.header2
  local header3 = layout.header3
  local left_pad = layout.header_left_pad
  local right_pad = layout.header_right_pad
  if layout.margin then
    vim.api.nvim_buf_set_lines(buffer, 0, -1, true, { (" "):rep(left_pad + 1) .. header1 .. (" "):rep(right_pad + 1) })
    vim.api.nvim_buf_set_lines(buffer, -1, -1, true, { header2_border_line(layout, header2) })
    vim.api.nvim_buf_set_lines(
      buffer,
      -1,
      -1,
      true,
      { "│" .. (" "):rep(left_pad) .. header3 .. (" "):rep(right_pad) .. "│" }
    )
    for _ = 1, height - 4 do
      vim.api.nvim_buf_set_lines(buffer, -1, -1, true, { "│" .. (" "):rep(width - 2) .. "│" })
    end
    vim.api.nvim_buf_set_lines(buffer, -1, -1, true, { "╰" .. ("─"):rep(width - 2) .. "╯" })
  else
    vim.api.nvim_buf_set_lines(buffer, 0, -1, true, { (" "):rep(left_pad) .. header1 .. (" "):rep(right_pad) })
    vim.api.nvim_buf_set_lines(buffer, -1, -1, true, { header2_border_line(layout, header2) })
    vim.api.nvim_buf_set_lines(buffer, -1, -1, true, { (" "):rep(left_pad) .. header3 .. (" "):rep(right_pad) })
    for _ = 1, height - 4 do
      vim.api.nvim_buf_set_lines(buffer, -1, -1, true, { " " })
    end
    vim.api.nvim_buf_set_lines(buffer, -1, -1, true, { ("─"):rep(width) })
  end
end

---@param buffer integer border buffer id
---@param layout table layout returned by compute_window_layout
---@param header2 string truncated header2 to show
local function set_border_header2(buffer, layout, header2)
  pcall(vim.api.nvim_buf_set_lines, buffer, 1, 2, false, { header2_border_line(layout, header2) })
end

---@param layout table layout returned by compute_window_layout
---@param source_id integer press tab id
---@param dest_id integer|nil hovered tab id
---@return string truncated header2 showing the directional swap labels during drag
local function drag_preview_header2(layout, source_id, dest_id)
  local available_width = layout.width - (layout.margin and 2 or 0)
  local header1, full_header2, header3 = build_tab_headers(source_id, layout.tab_padding)
  if dest_id ~= nil and dest_id ~= source_id then
    local tab_padding = layout.tab_padding
    -- Directional swap labels, keeping cell width stable. The arrow points at
    -- the cell it is drawn in, so that cell's own digit sits on its right.
    -- Normal cell is pad + 3 + pad; the bracketed label is (pad-1) + 5 + (pad-1),
    -- which fits every padded cell, so only padding 0 drops the brackets.
    local source_cell_label, dest_cell_label, side
    if tab_padding >= 1 then
      side = (" "):rep(tab_padding - 1)
      source_cell_label = "[" .. dest_id .. "→" .. source_id .. "]"
      dest_cell_label = "[" .. source_id .. "→" .. dest_id .. "]"
    else
      side = ""
      source_cell_label = dest_id .. "→" .. source_id
      dest_cell_label = source_id .. "→" .. dest_id
    end
    local pad = (" "):rep(tab_padding)
    local rebuilt = "┤"
    for i = 1, 10 do
      local digit = i % 10
      if digit == source_id then
        rebuilt = rebuilt .. side .. source_cell_label .. side
      elseif digit == dest_id then
        rebuilt = rebuilt .. side .. dest_cell_label .. side
      else
        rebuilt = rebuilt .. pad .. " " .. digit .. " " .. pad
      end
      rebuilt = rebuilt .. (i < 10 and "│" or "├")
    end
    full_header2 = rebuilt
  end
  local preview_hit_map = build_tab_hit_map(layout.tab_padding)
  _, full_header2, _ =
    truncate_tab_headers(header1, full_header2, header3, available_width, source_id, layout.margin, preview_hit_map)
  return full_header2
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

---Terminal slot shown in the terminal window, or nil when the window is
---closed or showing a buffer that is not a plugin terminal.
---@return integer|nil
function M.shown_terminal_slot()
  if M.terminal_window == nil or not vim.api.nvim_win_is_valid(M.terminal_window) then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(M.terminal_window))
  return tonumber(name:match("^term://Terminal%-(%d+)"))
end

---Slot navigation and relayout operate on: the slot the terminal window
---shows, falling back to the last activated slot.
---@return integer
function M.active_terminal_slot()
  return M.shown_terminal_slot() or M.last_terminal
end

local function relayout_current_terminal()
  if M.terminal_window == nil or not vim.api.nvim_win_is_valid(M.terminal_window) then
    return
  end
  local buffer = vim.api.nvim_win_get_buf(M.terminal_window)
  local id = M.active_terminal_slot()
  local append_mode = M.terminal_state[buffer] == true
  M.activate_terminal({
    id = id,
    toggle = false,
    append_mode = append_mode,
    relayout = true,
  })
end

function M.cycle_layout()
  local config = require("terminals").config
  local layouts = config.layouts
  if not layouts or #layouts == 0 then
    return
  end
  M.layout_index = (M.layout_index % #layouts) + 1
  relayout_current_terminal()
end

---@class TerminalLayout
---@field width integer
---@field height integer
---@field row integer
---@field col integer
---@field margin boolean
---@field tab_padding integer
---@field terminal_height integer
---@field header1 string
---@field header2 string
---@field header3 string
---@field tab_bar_width integer
---@field header_left_pad integer
---@field header_right_pad integer
---@field tab_id_by_char table<integer, integer> tab id (0-9) at each 0-indexed character of header2

---@param width_config number|string|nil
---@param height_config number|string|nil
---@param row_config number|string|nil
---@param col_config number|string|nil
---@param id integer
---@return TerminalLayout
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
  local tab_id_by_char = build_tab_hit_map(tab_padding)
  header1, header2, header3, tab_id_by_char =
    truncate_tab_headers(header1, header2, header3, available_tab_width, id, margin, tab_id_by_char)

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
    tab_id_by_char = tab_id_by_char,
  }
end

---Tab id (0-9) at a 0-indexed character position of the rendered tab bar,
---or nil when the position is not on a tab.
---@param layout TerminalLayout layout returned by compute_window_layout
---@param relative_index integer 0-indexed character index within header2
---@return integer|nil tab id (0-9) or nil when the index is not on a tab
function M.tab_id_at_header_index(layout, relative_index)
  if layout == nil or type(relative_index) ~= "number" or type(layout.tab_id_by_char) ~= "table" then
    return nil
  end
  return layout.tab_id_by_char[relative_index]
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
  local header_start = layout.header_left_pad + (layout.margin and 1 or 0)
  local relative_index = (click_wincol - 1) - header_start
  return M.tab_id_at_header_index(layout, relative_index)
end

---@return string keycode to feed: "" to swallow, otherwise the original key for native handling.
---Expr-safe: never changes buffers or windows synchronously (E565).
---Tab-bar work is deferred with vim.schedule so fast scrolls and clicks
---forward natively with their mouse position intact instead of being
---re-injected through feedkeys (whose raw 0x80 0xFD bytes leak into the
---pty as "ýK" when the typeahead fills up on fast scrolls).
function M._handle_mouse_pressed()
  local id = M.border_tab_under_mouse()
  if id ~= nil then
    M._mouse_press_tab_id = id
    vim.schedule(function()
      M._clear_drag_preview()
      M.activate_terminal({ id = id, toggle = false })
      if M._mouse_press_tab_id == id then
        M._show_drag_preview(id, id)
      end
    end)
    return ""
  end
  M._mouse_press_tab_id = nil
  if M._drag_preview ~= nil then
    vim.schedule(function()
      M._clear_drag_preview()
    end)
  end
  local mouse = vim.fn.getmousepos()
  if mouse.winid == 0 then
    return ""
  end
  return "<LeftMouse>"
end

---@return string keycode to feed: "" to swallow, otherwise the original key for native handling.
function M._handle_mouse_dragged()
  local press_id = M._mouse_press_tab_id
  if press_id == nil then
    local mouse = vim.fn.getmousepos()
    if mouse.winid == 0 then
      return ""
    end
    return "<LeftDrag>"
  end
  local id = M.drag_tab_under_mouse()
  vim.schedule(function()
    M._show_drag_preview(press_id, id)
  end)
  return ""
end

---@return string keycode to feed: "" to swallow, otherwise the original key for native handling.
function M._handle_mouse_released()
  local press_id = M._mouse_press_tab_id
  if press_id ~= nil then
    local release_id = M.drag_tab_under_mouse()
    M._mouse_press_tab_id = nil
    vim.schedule(function()
      if release_id ~= nil and release_id ~= press_id then
        M._clear_drag_preview()
        M.swap_terminals(press_id, release_id)
      else
        M._clear_drag_preview()
      end
    end)
    return ""
  end
  if M._drag_preview ~= nil then
    vim.schedule(function()
      M._clear_drag_preview()
    end)
  end
  local mouse = vim.fn.getmousepos()
  if mouse.winid == 0 then
    return ""
  end
  return "<LeftRelease>"
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

---@param layout TerminalLayout layout returned by compute_window_layout
---@param relative_index integer 0-indexed character index within header2
---@return integer|nil nearest visible tab id, clamping out-of-range positions to the edge tabs
local function nearest_tab_at_header_index(layout, relative_index)
  local exact = M.tab_id_at_header_index(layout, relative_index)
  if exact ~= nil then
    return exact
  end
  local length = vim.fn.strcharlen(layout.header2)
  if relative_index < length / 2 then
    for index = 0, length - 1 do
      local id = M.tab_id_at_header_index(layout, index)
      if id ~= nil then
        return id
      end
    end
  else
    for index = length - 1, 0, -1 do
      local id = M.tab_id_at_header_index(layout, index)
      if id ~= nil then
        return id
      end
    end
  end
  return nil
end

---@return integer|nil tab id under the mouse x-position, ignoring the y-position.
---Used during the dragging phase so a drag keeps its target while the mouse
---moves above or below the tab bar. Falls back to the strict tab-bar mapping
---when screen coordinates are unavailable.
function M.drag_tab_under_mouse()
  local layout = M.current_layout
  if layout == nil then
    return nil
  end
  if M.border_window == nil or not vim.api.nvim_win_is_valid(M.border_window) then
    return nil
  end
  local mouse = vim.fn.getmousepos()
  if mouse == nil or mouse.winid == 0 then
    return nil
  end
  if type(mouse.screencol) ~= "number" then
    return M.border_tab_under_mouse()
  end
  local ok, position = pcall(vim.api.nvim_win_get_position, M.border_window)
  if not ok or type(position) ~= "table" or type(position[2]) ~= "number" then
    return M.border_tab_under_mouse()
  end
  local header2 = layout.header2
  local left_pad = layout.header_left_pad
  if type(header2) ~= "string" or type(left_pad) ~= "number" then
    return nil
  end
  local header_start = left_pad + (layout.margin and 1 or 0)
  local relative_index = (mouse.screencol - 1) - position[2] - header_start
  return nearest_tab_at_header_index(layout, relative_index)
end

---@param layout TerminalLayout layout returned by compute_window_layout
---@param tab_id integer tab id (0-9)
---@return integer|nil start 0-indexed inclusive character index in header2, integer|nil end_exclusive character index
function M._tab_cell_char_range(layout, tab_id)
  if layout == nil or type(tab_id) ~= "number" then
    return nil
  end
  local length = vim.fn.strcharlen(layout.header2)
  local first = nil
  local last = nil
  for index = 0, length - 1 do
    if M.tab_id_at_header_index(layout, index) == tab_id then
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

---@class TabCellRanges
---@field area_start integer first character of the cell's label area in header2
---@field area_end integer end-exclusive character of the cell's label area in header2
---@field text_start integer first character of the label text
---@field text_end integer end-exclusive character of the label text

---Character ranges of one tab cell: its label area (the cell bounded by its
---border separators) and its label text (the area trimmed of padding spaces).
---@param buffer integer border buffer id
---@param layout table layout returned by compute_window_layout
---@param tab_id integer tab id (0-9)
---@return TabCellRanges|nil ranges nil when the cell holds no label text
local function tab_cell_ranges(buffer, layout, tab_id)
  local start_char, end_char = M._tab_cell_char_range(layout, tab_id)
  if start_char == nil or end_char == nil then
    return nil
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
    return nil
  end
  local area_start = start_char
  local area_end = end_char
  local header_offset = layout.header_left_pad + (layout.margin and 1 or 0)
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buffer, 1, 2, false)
  if not ok or type(lines) ~= "table" then
    return nil
  end
  local line = lines[1]
  if type(line) ~= "string" then
    return nil
  end
  local cell_text = vim.fn.strcharpart(line, header_offset + start_char, end_char - start_char)
  if type(cell_text) == "string" then
    local cell_length = vim.fn.strcharlen(cell_text)
    local first_text = nil
    local last_text = nil
    for index = 0, cell_length - 1 do
      if vim.fn.strcharpart(cell_text, index, 1) ~= " " then
        if first_text == nil then
          first_text = index
        end
        last_text = index
      end
    end
    if first_text == nil or last_text == nil then
      return nil
    end
    start_char = start_char + first_text
    end_char = start_char + (last_text - first_text + 1)
  end
  if end_char <= start_char then
    return nil
  end
  return {
    area_start = area_start,
    area_end = area_end,
    text_start = start_char,
    text_end = end_char,
  }
end

---Longest label text among two cells, so a pair of cells can flash at one
---shared width.
---@param buffer integer border buffer id
---@param layout table layout returned by compute_window_layout
---@param first integer tab id (0-9)
---@param second integer tab id (0-9)
---@return integer|nil length nil when either cell holds no label text
local function longest_label_length(buffer, layout, first, second)
  local first_ranges = tab_cell_ranges(buffer, layout, first)
  local second_ranges = tab_cell_ranges(buffer, layout, second)
  if first_ranges == nil or second_ranges == nil then
    return nil
  end
  return math.max(first_ranges.text_end - first_ranges.text_start, second_ranges.text_end - second_ranges.text_start)
end

---@param buffer integer border buffer id
---@param layout table layout returned by compute_window_layout
---@param tab_id integer tab id (0-9)
---@param highlight string highlight group name
---@param namespace integer namespace id for the extmark
---@param target_length integer|nil grow the highlight to this label text length, centered and
---clamped to the label area, so both cells of a pair render at the same width
local function highlight_tab_cell(buffer, layout, tab_id, highlight, namespace, target_length)
  local ranges = tab_cell_ranges(buffer, layout, tab_id)
  if ranges == nil then
    return
  end
  local start_char = ranges.text_start
  local end_char = ranges.text_end
  if target_length ~= nil and target_length > end_char - start_char then
    local missing = target_length - (end_char - start_char)
    local grow_left = math.min(math.floor(missing / 2), start_char - ranges.area_start)
    local grow_right = math.min(missing - grow_left, ranges.area_end - end_char)
    start_char = start_char - grow_left
    end_char = end_char + grow_right
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
  local target_length = longest_label_length(buffer, layout, first, second)
  highlight_tab_cell(buffer, layout, first, "TerminalsTabDragDest", SWAP_FLASH_NS, target_length)
  highlight_tab_cell(buffer, layout, second, "TerminalsTabDragDest", SWAP_FLASH_NS, target_length)
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
  local previous = M._drag_preview
  M._drag_preview = nil
  if M.border_window == nil or not vim.api.nvim_win_is_valid(M.border_window) then
    return
  end
  local ok, buffer = pcall(vim.api.nvim_win_get_buf, M.border_window)
  if not ok or buffer == nil then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, buffer, DRAG_PREVIEW_NS, 0, -1)
  if previous == nil then
    return
  end
  local layout = M.current_layout
  if layout == nil or type(layout.header2) ~= "string" then
    return
  end
  if type(previous.source) ~= "number" then
    return
  end
  local shown = drag_preview_header2(layout, previous.source, previous.dest)
  if shown ~= layout.header2 then
    set_border_header2(buffer, layout, layout.header2)
  end
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
  if type(source_id) == "number" and type(layout.header2) == "string" then
    local preview_header2 = drag_preview_header2(layout, source_id, dest_id)
    if preview_header2 ~= layout.header2 then
      set_border_header2(buffer, layout, preview_header2)
    elseif current ~= nil then
      local shown = nil
      if type(current.source) == "number" then
        shown = drag_preview_header2(layout, current.source, current.dest)
      end
      if shown ~= nil and shown ~= layout.header2 then
        set_border_header2(buffer, layout, layout.header2)
      end
    end
  end
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
  vim.schedule(function()
    M.navigate(direction)
  end)
  return true
end

---@param wheel_action string one of "up", "down", "left", "right"
---@param direction 1|-1 navigation direction matching the wheel action
---@return string keycode to feed: "" to swallow, otherwise the original wheel key for native handling.
function M._handle_scroll(wheel_action, direction)
  if M.handle_tab_scroll(direction) then
    return ""
  end
  local mouse = vim.fn.getmousepos()
  if mouse.winid == 0 then
    return ""
  end
  if wheel_action == "up" then
    return "<ScrollWheelUp>"
  elseif wheel_action == "down" then
    return "<ScrollWheelDown>"
  elseif wheel_action == "left" then
    return "<ScrollWheelLeft>"
  elseif wheel_action == "right" then
    return "<ScrollWheelRight>"
  end
  return ""
end

---@param direction 1|-1
function M.navigate(direction)
  if M.terminal_window ~= nil and vim.api.nvim_win_is_valid(M.terminal_window) then
    local next_terminal = (M.active_terminal_slot() + direction + 10) % 10
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
  local first_name = "term://Terminal-" .. first
  local second_name = "term://Terminal-" .. second
  local first_buffer = vim.fn.bufnr(first_name)
  local second_buffer = vim.fn.bufnr(second_name)
  if first_buffer == -1 and second_buffer == -1 then
    M.activate_terminal({ id = second, toggle = false })
    return
  end
  local function delete_leftover(name)
    local leftover = vim.fn.bufnr(name)
    if leftover ~= -1 and leftover ~= first_buffer and leftover ~= second_buffer then
      vim.api.nvim_buf_delete(leftover, { force = true })
    end
  end
  if first_buffer ~= -1 then
    vim.api.nvim_buf_set_name(first_buffer, "term://Terminal-Temporary")
    delete_leftover(first_name)
  end
  if second_buffer ~= -1 then
    vim.api.nvim_buf_set_name(second_buffer, first_name)
    delete_leftover(second_name)
  end
  if first_buffer ~= -1 then
    vim.api.nvim_buf_set_name(first_buffer, second_name)
    delete_leftover("term://Terminal-Temporary")
  end
  M.activate_terminal({ id = second, toggle = false })
  M._flash_swap_tabs(first, second)
end

---@param direction 1|-1
function M.move_terminal(direction)
  if M.terminal_window ~= nil and vim.api.nvim_win_is_valid(M.terminal_window) then
    local current = M.active_terminal_slot()
    local other = (current + direction + 10) % 10
    M.swap_terminals(current, other)
  elseif direction == 1 then
    vim.cmd.tabmove("+")
  elseif direction == -1 then
    vim.cmd.tabmove("-")
  end
end

---Single source for every action the plugin maps. The global and the
---terminal-buffer registrations differ only in which modes they attach
---these handlers to.
local keymap_handlers = {
  go_left = function()
    M.navigate(-1)
  end,
  go_right = function()
    M.navigate(1)
  end,
  move_left = function()
    M.move_terminal(-1)
  end,
  move_right = function()
    M.move_terminal(1)
  end,
  toggle = function()
    M.toggle_terminal()
  end,
  cycle_layout = function()
    M.cycle_layout()
  end,
  focus = function()
    M.enter_terminal()
    vim.cmd.startinsert()
  end,
  mouse_pressed = function()
    return M._handle_mouse_pressed()
  end,
  mouse_dragged = function()
    return M._handle_mouse_dragged()
  end,
  mouse_released = function()
    return M._handle_mouse_released()
  end,
  scroll_up = function()
    return M._handle_scroll("up", -1)
  end,
  scroll_down = function()
    return M._handle_scroll("down", 1)
  end,
  scroll_left = function()
    return M._handle_scroll("left", -1)
  end,
  scroll_right = function()
    return M._handle_scroll("right", 1)
  end,
}

---@class KeymapDefinition
---@field modes string[] modes the mapping applies to
---@field lhs string
---@field rhs string|function
---@field expr? boolean

---Applies keymap definitions globally or to the current buffer.
---@param definitions KeymapDefinition[]
---@param buffer boolean|nil true maps the current buffer, nil maps globally
local function register_keymaps(definitions, buffer)
  for _, definition in ipairs(definitions) do
    vim.keymap.set(definition.modes, definition.lhs, definition.rhs, {
      buffer = buffer,
      silent = true,
      expr = definition.expr or false,
    })
  end
end

---Slot mappings for the modifier digit keys.
---@param config TerminalsConfig
---@param mode string
---@return KeymapDefinition[]
local function slot_keymap_definitions(config, mode)
  local definitions = {}
  for slot = 0, 9 do
    definitions[#definitions + 1] = {
      modes = { mode },
      lhs = ("<%s-%s>"):format(config.keys.modifier, slot),
      rhs = function()
        M.activate_terminal({ id = slot })
      end,
    }
  end
  return definitions
end

---Mouse and scroll-wheel mappings for the given modes.
---@param modes string[]
---@return KeymapDefinition[]
local function mouse_keymap_definitions(modes)
  return {
    { modes = modes, lhs = "<LeftMouse>", rhs = keymap_handlers.mouse_pressed, expr = true },
    { modes = modes, lhs = "<LeftDrag>", rhs = keymap_handlers.mouse_dragged, expr = true },
    { modes = modes, lhs = "<LeftRelease>", rhs = keymap_handlers.mouse_released, expr = true },
    { modes = modes, lhs = "<ScrollWheelUp>", rhs = keymap_handlers.scroll_up, expr = true },
    { modes = modes, lhs = "<ScrollWheelDown>", rhs = keymap_handlers.scroll_down, expr = true },
    { modes = modes, lhs = "<ScrollWheelLeft>", rhs = keymap_handlers.scroll_left, expr = true },
    { modes = modes, lhs = "<ScrollWheelRight>", rhs = keymap_handlers.scroll_right, expr = true },
  }
end

---Global keymaps, registered once by setup().
---@param config TerminalsConfig
---@return KeymapDefinition[]
local function global_keymap_definitions(config)
  local definitions = {
    { modes = { "n" }, lhs = config.keys.go_left, rhs = keymap_handlers.go_left },
    { modes = { "n" }, lhs = config.keys.go_right, rhs = keymap_handlers.go_right },
    { modes = { "n" }, lhs = config.keys.move_left, rhs = keymap_handlers.move_left },
    { modes = { "n" }, lhs = config.keys.move_right, rhs = keymap_handlers.move_right },
    { modes = { "n" }, lhs = config.keys.toggle_reverse_search, rhs = "?" },
    { modes = { "i" }, lhs = config.keys.toggle_reverse_search, rhs = "<c-c>?" },
    { modes = { "n" }, lhs = config.keys.toggle, rhs = keymap_handlers.toggle },
  }
  vim.list_extend(definitions, slot_keymap_definitions(config, "n"))
  vim.list_extend(definitions, mouse_keymap_definitions({ "n", "i", "v" }))
  return definitions
end

---Buffer-local keymaps for terminal buffers, registered by
---leave_terminal() on TermOpen and when input mode is left.
---@param config TerminalsConfig
---@return KeymapDefinition[]
local function terminal_keymap_definitions(config)
  -- Preserved keys come first so an overlapping built-in key keeps its
  -- built-in behavior.
  local definitions = {}
  for _, key in ipairs(config.preserved_keys) do
    definitions[#definitions + 1] = { modes = { "t" }, lhs = key, rhs = ("<c-\\><c-n>%s"):format(key) }
  end
  vim.list_extend(definitions, {
    { modes = { "t" }, lhs = config.keys.focus, rhs = keymap_handlers.focus },
    { modes = { "t" }, lhs = config.keys.paste, rhs = "<c-\\><c-n>pa" },
    { modes = { "t" }, lhs = config.keys.paste_in_place, rhs = "<c-\\><c-n>Pa" },
    { modes = { "t" }, lhs = config.keys.go_left, rhs = keymap_handlers.go_left },
    { modes = { "t" }, lhs = config.keys.go_right, rhs = keymap_handlers.go_right },
    { modes = { "t" }, lhs = config.keys.move_left, rhs = keymap_handlers.move_left },
    { modes = { "t" }, lhs = config.keys.move_right, rhs = keymap_handlers.move_right },
    { modes = { "t" }, lhs = config.keys.toggle, rhs = keymap_handlers.toggle },
    { modes = { "t" }, lhs = config.keys.cycle_layout, rhs = keymap_handlers.cycle_layout },
    { modes = { "n" }, lhs = config.keys.cycle_layout, rhs = keymap_handlers.cycle_layout },
    { modes = { "t" }, lhs = config.keys.toggle_reverse_search, rhs = "<c-\\><c-n>?" },
    { modes = { "t" }, lhs = config.keys.leave, rhs = "<c-\\><c-n>" },
  })
  vim.list_extend(definitions, slot_keymap_definitions(config, "t"))
  vim.list_extend(definitions, mouse_keymap_definitions({ "t", "n" }))
  return definitions
end

---Registers the plugin's global keymaps. Called by setup().
function M.register_global_keymaps()
  register_keymaps(global_keymap_definitions(require("terminals").config), nil)
end

function M.enter_terminal()
  local config = require("terminals").config
  for codepoint = 1, 126 do
    vim.keymap.set(
      "t",
      ("<d-char-%s>"):format(codepoint),
      ("<char-24><char-64>s<char-%s>"):format(codepoint),
      { noremap = true, buffer = true }
    )
  end
  vim.keymap.set("t", config.keys.unfocus, function()
    M.leave_terminal()
    vim.cmd.startinsert()
  end, { buffer = true })
end

function M.leave_terminal()
  for codepoint = 1, 126 do
    pcall(vim.keymap.del, { "t", ("<d-char-%s>"):format(codepoint) })
  end

  register_keymaps(terminal_keymap_definitions(require("terminals").config), true)
end

---Runs an operation while window-leave events are treated as terminal
---switches rather than closes, releasing the guard even when the operation
---fails.
---@param operation function
local function during_terminal_switch(operation)
  M.switching_terminals = true
  local ok, err = xpcall(operation, debug.traceback)
  M.switching_terminals = false
  if not ok then
    error(err, 0)
  end
end

---Creates or reconfigures the terminal windows for the requested slot.
---@param opts ActivateTerminalOptions
local function activate_terminal_impl(opts)
  local id = 1
  local toggle = opts["toggle"] == nil or opts["toggle"]
  local append_mode = opts["append_mode"] == nil or opts["append_mode"]
  if opts["id"] ~= nil then
    id = opts["id"]
  end
  M.last_terminal = id
  if opts["id"] ~= nil then
    if M.terminal_window ~= nil and vim.api.nvim_win_is_valid(M.terminal_window) then
      local current = M.shown_terminal_slot()
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

  local bufnr = vim.fn.bufnr(buffer_name)
  if bufnr ~= -1 then
    if vim.api.nvim_get_option_value("buftype", { buf = bufnr }) == "terminal" then
      should_create = false
      buffer = bufnr
    else
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end

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
  render_border_buffer(border_buffer, layout)

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
end

--- @param opts ActivateTerminalOptions|nil
function M.activate_terminal(opts)
  M._save_current_terminal_state()
  during_terminal_switch(function()
    activate_terminal_impl(opts or {})
  end)
end

function M.close_terminal()
  during_terminal_switch(function()
    M._mouse_press_tab_id = nil
    M._drag_preview = nil
    M._clear_swap_flash()
    if M.terminal_window ~= nil and vim.api.nvim_win_is_valid(M.terminal_window) then
      vim.api.nvim_win_close(M.terminal_window, false)
    end
    if M.border_window ~= nil and vim.api.nvim_win_is_valid(M.border_window) then
      vim.api.nvim_win_close(M.border_window, false)
    end
  end)
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

function M.handle_resize()
  relayout_current_terminal()
end

return M
