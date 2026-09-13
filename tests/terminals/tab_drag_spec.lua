local logic = require("terminals.logic")

describe("tab drag", function()
  local original_columns
  local original_lines
  local original_getmousepos
  local original_input_mouse
  local original_activate

  before_each(function()
    original_columns = vim.o.columns
    original_lines = vim.o.lines
    original_getmousepos = vim.fn.getmousepos
    original_input_mouse = vim.api.nvim_input_mouse
    original_activate = logic.activate_terminal
    logic._mouse_press_tab_id = nil
    logic._drag_preview = nil
  end)

  after_each(function()
    vim.o.columns = original_columns
    vim.o.lines = original_lines
    vim.fn.getmousepos = original_getmousepos
    vim.api.nvim_input_mouse = original_input_mouse
    logic.activate_terminal = original_activate
    logic._mouse_press_tab_id = nil
    logic._drag_preview = nil
    pcall(logic._clear_swap_flash)
    for i = 0, 9 do
      local existing = vim.fn.bufnr("term://Terminal-" .. i)
      if existing ~= -1 then
        vim.api.nvim_buf_delete(existing, { force = true })
      end
    end
    local temp = vim.fn.bufnr("term://Terminal-Temporary")
    if temp ~= -1 then
      vim.api.nvim_buf_delete(temp, { force = true })
    end
    if logic.border_window ~= nil and vim.api.nvim_win_is_valid(logic.border_window) then
      vim.api.nvim_win_close(logic.border_window, true)
    end
    if logic.terminal_window ~= nil and vim.api.nvim_win_is_valid(logic.terminal_window) then
      vim.api.nvim_win_close(logic.terminal_window, true)
    end
    logic.border_window = nil
    logic.terminal_window = nil
    logic.current_layout = nil
    logic.switching_terminals = false
  end)

  local function open_border(active_id)
    vim.o.columns = 200
    vim.o.lines = 40
    local layout = logic.compute_window_layout(nil, nil, nil, nil, active_id or 1)
    local border_buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(border_buffer, 0, -1, true, {
      (" "):rep(layout.header_left_pad) .. layout.header1,
      ("-"):rep(layout.header_left_pad) .. layout.header2,
      (" "):rep(layout.header_left_pad) .. layout.header3,
    })
    local border_window = vim.api.nvim_open_win(border_buffer, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 20,
      height = 5,
    })
    logic.border_window = border_window
    logic.current_layout = layout
    return layout, border_window
  end

  local function wincol_for(layout, id)
    local cell = (id + 9) % 10
    local cell_width = layout.tab_padding * 2 + 4
    local digit = 1 + cell * cell_width + layout.tab_padding + 1
    return layout.header_left_pad + (layout.margin and 1 or 0) + 1 + digit
  end

  describe("swap_terminals", function()
    it("swaps two slots through the shared gate and activates the destination", function()
      local first = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(first, "term://Terminal-2")
      local second = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(second, "term://Terminal-7")
      logic.terminal_window = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
        relative = "editor",
        row = 10,
        col = 10,
        width = 20,
        height = 5,
      })
      local captured = nil
      logic.activate_terminal = function(opts)
        captured = opts
      end
      logic.swap_terminals(2, 7)
      assert.equals("term://Terminal-7", vim.api.nvim_buf_get_name(first))
      assert.equals("term://Terminal-2", vim.api.nvim_buf_get_name(second))
      assert.equals(-1, vim.fn.bufnr("term://Terminal-Temporary"))
      assert.is_not_nil(captured)
      assert.equals(7, captured.id)
      assert.equals(false, captured.toggle)
    end)

    it("moves to an empty slot", function()
      local first = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(first, "term://Terminal-2")
      logic.terminal_window = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
        relative = "editor",
        row = 10,
        col = 10,
        width = 20,
        height = 5,
      })
      local captured = nil
      logic.activate_terminal = function(opts)
        captured = opts
      end
      logic.swap_terminals(2, 5)
      assert.equals("term://Terminal-5", vim.api.nvim_buf_get_name(first))
      assert.equals(-1, vim.fn.bufnr("term://Terminal-2"))
      assert.equals(5, captured.id)
    end)

    it("ignores same-slot and invalid swaps", function()
      local captured = nil
      logic.activate_terminal = function(opts)
        captured = opts
      end
      logic.swap_terminals(2, 2)
      logic.swap_terminals(nil, 2)
      logic.swap_terminals(2, nil)
      assert.is_nil(captured)
    end)
  end)

  describe("drag preview", function()
    it("maps a visible cell range that resolves back to the tab", function()
      local layout = logic.compute_window_layout(nil, nil, nil, 1)
      vim.o.columns = 200
      vim.o.lines = 40
      layout = logic.compute_window_layout(nil, nil, nil, nil, 1)
      for _, id in ipairs({ 1, 2, 0 }) do
        local first, last = logic._tab_cell_char_range(layout, id)
        assert.is_not_nil(first)
        assert.is_not_nil(last)
        local middle = math.floor((first + last - 1) / 2)
        assert.equals(id, logic.tab_id_at_header_index(layout.header2, layout.tab_padding, middle))
      end
      assert.is_nil(logic._tab_cell_char_range(layout, nil))
      assert.is_nil(logic._tab_cell_char_range(nil, 1))
    end)

    it("shows and clears source and destination highlights", function()
      local layout, _ = open_border(2)
      logic._show_drag_preview(2, 7)
      assert.same({ source = 2, dest = 7 }, logic._drag_preview)
      local namespace = vim.api.nvim_create_namespace("terminals_tab_drag")
      local buffer = vim.api.nvim_win_get_buf(logic.border_window)
      local marks = vim.api.nvim_buf_get_extmarks(buffer, namespace, 0, -1, { details = true })
      assert.is_true(#marks >= 2)
      logic._clear_drag_preview()
      assert.is_nil(logic._drag_preview)
      assert.equals(0, #vim.api.nvim_buf_get_extmarks(buffer, namespace, 0, -1, { details = true }))
      assert.is_not_nil(layout)
    end)
  end)

  describe("press/drag/release", function()
    it("commits a swap when released on a different tab", function()
      local layout, border_window = open_border(2)
      logic.terminal_window = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
        relative = "editor",
        row = 10,
        col = 10,
        width = 20,
        height = 5,
      })
      local swapped = nil
      local swap_original = logic.swap_terminals
      logic.swap_terminals = function(first, second)
        swapped = { first, second }
      end
      logic.activate_terminal = function() end
      vim.fn.getmousepos = function()
        return { winid = border_window, line = 2, wincol = wincol_for(layout, 2) }
      end
      logic._handle_mouse_pressed()
      assert.equals(2, logic._mouse_press_tab_id)
      vim.wait(30)
      vim.fn.getmousepos = function()
        return { winid = border_window, line = 2, wincol = wincol_for(layout, 7) }
      end
      logic._handle_mouse_dragged()
      assert.same({ source = 2, dest = 7 }, logic._drag_preview)
      logic._handle_mouse_released()
      assert.same({ 2, 7 }, swapped)
      assert.is_nil(logic._mouse_press_tab_id)
      assert.is_nil(logic._drag_preview)
      logic.swap_terminals = swap_original
    end)

    it("keeps the source highlight when dragged back to the source tab", function()
      local layout, border_window = open_border(2)
      logic.terminal_window = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
        relative = "editor",
        row = 10,
        col = 10,
        width = 20,
        height = 5,
      })
      local swapped = false
      local swap_original = logic.swap_terminals
      logic.swap_terminals = function()
        swapped = true
      end
      logic.activate_terminal = function() end
      vim.fn.getmousepos = function()
        return { winid = border_window, line = 2, wincol = wincol_for(layout, 2) }
      end
      logic._handle_mouse_pressed()
      vim.wait(30)
      assert.same({ source = 2, dest = 2 }, logic._drag_preview)
      vim.fn.getmousepos = function()
        return { winid = border_window, line = 2, wincol = wincol_for(layout, 7) }
      end
      logic._handle_mouse_dragged()
      assert.same({ source = 2, dest = 7 }, logic._drag_preview)
      vim.fn.getmousepos = function()
        return { winid = border_window, line = 2, wincol = wincol_for(layout, 2) }
      end
      logic._handle_mouse_dragged()
      assert.same({ source = 2, dest = 2 }, logic._drag_preview)
      logic._handle_mouse_released()
      assert.is_false(swapped)
      assert.is_nil(logic._mouse_press_tab_id)
      assert.is_nil(logic._drag_preview)
      logic.swap_terminals = swap_original
    end)

    it("keeps the source highlight while the button is down off the tab bar", function()
      local layout, border_window = open_border(2)
      logic.activate_terminal = function() end
      vim.fn.getmousepos = function()
        return { winid = border_window, line = 2, wincol = wincol_for(layout, 2) }
      end
      logic._handle_mouse_pressed()
      vim.wait(30)
      assert.same({ source = 2, dest = 2 }, logic._drag_preview)
      vim.fn.getmousepos = function()
        return { winid = 999999, line = 2, wincol = 10 }
      end
      logic._handle_mouse_dragged()
      assert.same({ source = 2, dest = nil }, logic._drag_preview)
      local buffer = vim.api.nvim_win_get_buf(border_window)
      local namespace = vim.api.nvim_create_namespace("terminals_tab_drag")
      assert.is_true(#vim.api.nvim_buf_get_extmarks(buffer, namespace, 0, -1, { details = true }) >= 1)
      logic._handle_mouse_released()
      assert.is_nil(logic._drag_preview)
    end)

    it("forwards drags that did not start on a tab", function()
      local _, border_window = open_border(1)
      local forwarded = {}
      local original_feedkeys = vim.api.nvim_feedkeys
      vim.api.nvim_feedkeys = function(keys, mode, escape)
        table.insert(forwarded, { keys = keys, mode = mode })
      end
      vim.fn.getmousepos = function()
        return { winid = border_window, line = 5, wincol = 5, screenrow = 10, screencol = 10 }
      end
      logic._handle_mouse_pressed()
      assert.is_nil(logic._mouse_press_tab_id)
      vim.fn.getmousepos = function()
        return { winid = 999999, line = 2, wincol = 10, screenrow = 11, screencol = 11 }
      end
      logic._handle_mouse_dragged()
      logic._handle_mouse_released()
      vim.api.nvim_feedkeys = original_feedkeys
      assert.equals(3, #forwarded)
      for _, entry in ipairs(forwarded) do
        assert.equals("n", entry.mode)
        assert.is_true(#entry.keys > 0)
      end
    end)
  end)

  describe("swap flash", function()
    it("flashes both swapped tabs through one shared gate", function()
      local layout, border_window = open_border(7)
      local first = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(first, "term://Terminal-2")
      local second = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(second, "term://Terminal-7")
      logic.terminal_window = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
        relative = "editor",
        row = 10,
        col = 10,
        width = 20,
        height = 5,
      })
      logic.activate_terminal = function(opts)
        local fresh = logic.compute_window_layout(nil, nil, nil, nil, opts.id)
        logic.current_layout = fresh
        local buffer = vim.api.nvim_win_get_buf(border_window)
        local left = fresh.header_left_pad
        local right = fresh.header_right_pad
        vim.api.nvim_buf_set_lines(buffer, 0, -1, true, {
          (" "):rep(left + 1) .. fresh.header1 .. (" "):rep(right + 1),
          "╭" .. ("─"):rep(left) .. fresh.header2 .. ("─"):rep(right) .. "╮",
          "│" .. (" "):rep(left) .. fresh.header3 .. (" "):rep(right) .. "│",
        })
      end
      logic.swap_terminals(2, 7)
      local buffer = vim.api.nvim_win_get_buf(border_window)
      local namespace = vim.api.nvim_create_namespace("terminals_tab_swap")
      local marks = vim.api.nvim_buf_get_extmarks(buffer, namespace, 0, -1, { details = true })
      assert.equals(2, #marks)
      for _, mark in ipairs(marks) do
        assert.equals("TerminalsTabDragDest", mark[4].hl_group)
      end
      assert.is_not_nil(layout)
    end)

    it("runs the same flash for keyboard and drag swaps", function()
      local layout, border_window = open_border(2)
      local first = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(first, "term://Terminal-2")
      local second = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(second, "term://Terminal-3")
      logic.terminal_window = vim.api.nvim_open_win(first, false, {
        relative = "editor",
        row = 10,
        col = 10,
        width = 20,
        height = 5,
      })
      vim.api.nvim_set_current_buf(first)
      local flashed = {}
      local flash_original = logic._flash_swap_tabs
      logic._flash_swap_tabs = function(a, b)
        table.insert(flashed, { a, b })
      end
      local activate_original = logic.activate_terminal
      logic.activate_terminal = function() end
      logic.move_terminal(1)
      vim.fn.getmousepos = function()
        return { winid = border_window, line = 2, wincol = wincol_for(layout, 2) }
      end
      logic._handle_mouse_pressed()
      vim.wait(30)
      vim.fn.getmousepos = function()
        return { winid = border_window, line = 2, wincol = wincol_for(layout, 3) }
      end
      logic._handle_mouse_dragged()
      logic._handle_mouse_released()
      logic._flash_swap_tabs = flash_original
      logic.activate_terminal = activate_original
      assert.same({ { 2, 3 }, { 2, 3 } }, flashed)
    end)
  end)

  describe("keymaps", function()
    it("registers global and buffer-local drag mappings", function()
      require("terminals").setup()
      assert.not_equals("", vim.fn.maparg("<LeftDrag>", "n"))
      local buffer = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buffer)
      logic.leave_terminal()
      local found = { t = false, n = false }
      for _, mode in ipairs({ "t", "n" }) do
        for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(buffer, mode)) do
          if keymap.lhs == "<LeftDrag>" then
            found[mode] = true
          end
        end
      end
      assert.is_true(found.t)
      assert.is_true(found.n)
    end)
  end)
end)
