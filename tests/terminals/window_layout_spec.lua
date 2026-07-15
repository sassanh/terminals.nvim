local logic = require("terminals.logic")

describe("window layout", function()
  local original_columns
  local original_lines

  before_each(function()
    original_columns = vim.o.columns
    original_lines = vim.o.lines
  end)

  after_each(function()
    vim.o.columns = original_columns
    vim.o.lines = original_lines
  end)

  it("uses legacy defaults when width and height are unset", function()
    vim.o.columns = 120
    vim.o.lines = 40

    local layout = logic.compute_window_layout(nil, nil, nil, nil, 1)

    assert.equals(115, layout.width)
    assert.equals(39, layout.height)
    assert.equals(0, layout.row)
    assert.equals(2, layout.col)
    assert.equals(3, layout.tab_padding)
    assert.equals(101, layout.tab_bar_width)
  end)

  it("resolves fixed width and height", function()
    vim.o.columns = 120
    vim.o.lines = 40

    local layout = logic.compute_window_layout(80, 30, nil, nil, 1)

    assert.equals(80, layout.width)
    assert.equals(30, layout.height)
    assert.equals(0, layout.row)
    assert.equals(20, layout.col)
  end)

  it("resolves percentage width and height", function()
    vim.o.columns = 100
    vim.o.lines = 50

    local layout = logic.compute_window_layout("50%", "80%", nil, nil, 1)

    assert.equals(50, layout.width)
    assert.equals(40, layout.height)
    assert.equals(0, layout.row)
    assert.equals(25, layout.col)
  end)

  it("clamps width and height to minimums as the last step", function()
    vim.o.columns = 120
    vim.o.lines = 40

    local layout = logic.compute_window_layout(10, 2, nil, nil, 1)

    assert.equals(26, layout.width)
    assert.equals(4, layout.height)
    assert.equals(0, layout.row)
    assert.equals(47, layout.col)
    assert.equals(0, layout.terminal_height)
  end)

  it("reduces tab padding when the tab bar does not fit", function()
    vim.o.columns = 80
    vim.o.lines = 40

    local full = logic.compute_window_layout(101, 30, nil, nil, 1)
    local compact = logic.compute_window_layout(80, 30, nil, nil, 1)
    local tighter = logic.compute_window_layout(60, 30, nil, nil, 1)

    assert.equals(3, full.tab_padding)
    assert.equals(101, full.tab_bar_width)

    assert.equals(1, compact.tab_padding)
    assert.equals(61, compact.tab_bar_width)

    assert.equals(0, tighter.tab_padding)
    assert.equals(41, tighter.tab_bar_width)
  end)

  it("truncates the tab bar when width is below the minimum padded size", function()
    vim.o.columns = 40
    vim.o.lines = 40

    local layout = logic.compute_window_layout(30, 30, nil, nil, 6)

    assert.equals(0, layout.tab_padding)
    assert.equals(41, layout.tab_bar_width)
    assert.is_true(vim.fn.strcharlen(layout.header1) <= 30)
  end)

  it("resolves fixed and percentage positioning", function()
    vim.o.columns = 100
    vim.o.lines = 50

    local fixed = logic.compute_window_layout(40, 20, 5, 10, 1)
    local percent = logic.compute_window_layout(40, 20, "10%", "25%", 1)

    assert.equals(5, fixed.row)
    assert.equals(10, fixed.col)
    assert.equals(5, percent.row)
    assert.equals(25, percent.col)
  end)

  it("supports alignment keywords for positioning", function()
    vim.o.columns = 100
    vim.o.lines = 50

    local centered = logic.compute_window_layout(40, 20, "center", "center", 1)
    local bottom_right = logic.compute_window_layout(40, 20, "bottom", "right", 1)

    assert.equals(15, centered.row)
    assert.equals(30, centered.col)
    assert.equals(30, bottom_right.row)
    assert.equals(60, bottom_right.col)
  end)

  it("clamps position so the window stays on screen", function()
    vim.o.columns = 100
    vim.o.lines = 50

    local layout = logic.compute_window_layout(40, 20, 100, 100, 1)

    assert.equals(30, layout.row)
    assert.equals(60, layout.col)
  end)
end)