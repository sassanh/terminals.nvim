local logic = require("terminals.logic")

describe("border render", function()
  local original_columns
  local original_lines

  before_each(function()
    original_columns = vim.o.columns
    original_lines = vim.o.lines
    vim.o.lines = 40
  end)

  after_each(function()
    vim.o.columns = original_columns
    vim.o.lines = original_lines
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

  it("frames the tab bar when the editor is wide enough for a margin", function()
    vim.o.columns = 200
    logic.activate_terminal({ id = 1 })
    vim.cmd("stopinsert")

    local layout = logic.current_layout
    assert.is_true(layout.margin)
    local left_pad = layout.header_left_pad
    local right_pad = layout.header_right_pad
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(logic.border_window), 0, -1, false)

    assert.equals(layout.height, #lines)
    assert.equals((" "):rep(left_pad + 1) .. layout.header1 .. (" "):rep(right_pad + 1), lines[1])
    assert.equals("╭" .. ("─"):rep(left_pad) .. layout.header2 .. ("─"):rep(right_pad) .. "╮", lines[2])
    assert.equals("│" .. (" "):rep(left_pad) .. layout.header3 .. (" "):rep(right_pad) .. "│", lines[3])
    assert.equals("╰" .. ("─"):rep(layout.width - 2) .. "╯", lines[#lines])
  end)

  it("draws the tab bar without a frame on narrow editors", function()
    vim.o.columns = 100
    logic.activate_terminal({ id = 1 })
    vim.cmd("stopinsert")

    local layout = logic.current_layout
    assert.is_false(layout.margin)
    local left_pad = layout.header_left_pad
    local right_pad = layout.header_right_pad
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(logic.border_window), 0, -1, false)

    assert.equals(layout.height, #lines)
    assert.equals((" "):rep(left_pad) .. layout.header1 .. (" "):rep(right_pad), lines[1])
    assert.equals(("─"):rep(left_pad) .. layout.header2 .. ("─"):rep(right_pad), lines[2])
    assert.equals((" "):rep(left_pad) .. layout.header3 .. (" "):rep(right_pad), lines[3])
    assert.equals(("─"):rep(layout.width), lines[#lines])
  end)
end)
