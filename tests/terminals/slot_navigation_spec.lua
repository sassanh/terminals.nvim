local logic = require("terminals.logic")

describe("slot navigation", function()
  local original_columns
  local original_lines
  local original_getmousepos
  local main_window

  local function wincol_for(layout, id)
    local cell = (id + 9) % 10
    local cell_width = layout.tab_padding * 2 + 4
    local digit = 1 + cell * cell_width + layout.tab_padding + 1
    return layout.header_left_pad + (layout.margin and 1 or 0) + 1 + digit
  end

  before_each(function()
    original_columns = vim.o.columns
    original_lines = vim.o.lines
    original_getmousepos = vim.fn.getmousepos
    vim.o.columns = 200
    vim.o.lines = 40
    vim.cmd.edit(vim.fn.tempname() .. ".lua")
    main_window = vim.api.nvim_get_current_win()
  end)

  after_each(function()
    vim.o.columns = original_columns
    vim.o.lines = original_lines
    vim.fn.getmousepos = original_getmousepos
    pcall(logic._clear_swap_flash)
    pcall(logic.close_terminal)
    for slot = 0, 9 do
      local existing = vim.fn.bufnr("term://Terminal-" .. slot)
      if existing ~= -1 then
        vim.api.nvim_buf_delete(existing, { force = true })
      end
    end
    local temporary = vim.fn.bufnr("term://Terminal-Temporary")
    if temporary ~= -1 then
      vim.api.nvim_buf_delete(temporary, { force = true })
    end
    if logic.terminal_window ~= nil and vim.api.nvim_win_is_valid(logic.terminal_window) then
      vim.api.nvim_win_close(logic.terminal_window, true)
    end
    if logic.border_window ~= nil and vim.api.nvim_win_is_valid(logic.border_window) then
      vim.api.nvim_win_close(logic.border_window, true)
    end
    logic.border_window = nil
    logic.terminal_window = nil
    logic.current_layout = nil
    logic.switching_terminals = false
    logic.last_terminal = 1
  end)

  it("reports the slot shown in the terminal window", function()
    logic.activate_terminal({ id = 4 })
    vim.cmd("stopinsert")
    assert.equals(4, logic.shown_terminal_slot())
    assert.equals(4, logic.active_terminal_slot())
  end)

  it("falls back to the last activated slot when the popup is closed", function()
    logic.activate_terminal({ id = 4 })
    vim.cmd("stopinsert")
    logic.close_terminal()
    assert.is_nil(logic.shown_terminal_slot())
    assert.equals(4, logic.active_terminal_slot())
  end)

  it("wraps around the slots in both directions", function()
    logic.activate_terminal({ id = 9 })
    vim.cmd("stopinsert")
    logic.navigate(1)
    assert.equals(0, logic.shown_terminal_slot())
    logic.navigate(-1)
    assert.equals(9, logic.shown_terminal_slot())
  end)

  it("navigates from the popup slot while another buffer is focused", function()
    logic.activate_terminal({ id = 1 })
    vim.cmd("stopinsert")
    local layout = logic.current_layout
    -- the mouse rests on the active tab, which keeps the popup open when
    -- keyboard focus moves to the main window
    vim.fn.getmousepos = function()
      return { winid = logic.border_window, line = 2, wincol = wincol_for(layout, 1) }
    end
    vim.api.nvim_set_current_win(main_window)
    assert.is_true(vim.api.nvim_win_is_valid(logic.terminal_window))
    assert.not_equals("term://Terminal-1", vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()))

    local ok = pcall(logic.navigate, 1)
    assert.is_true(ok, "navigate must not error while another buffer is focused")
    assert.equals(2, logic.shown_terminal_slot())
  end)

  it("moves the popup slot while another buffer is focused", function()
    logic.activate_terminal({ id = 1 })
    vim.cmd("stopinsert")
    local layout = logic.current_layout
    vim.fn.getmousepos = function()
      return { winid = logic.border_window, line = 2, wincol = wincol_for(layout, 1) }
    end
    vim.api.nvim_set_current_win(main_window)
    assert.is_true(vim.api.nvim_win_is_valid(logic.terminal_window))

    local ok = pcall(logic.move_terminal, 1)
    assert.is_true(ok, "move_terminal must not error while another buffer is focused")
    assert.equals(2, logic.shown_terminal_slot())
    assert.equals(-1, vim.fn.bufnr("term://Terminal-1"))
  end)
end)
