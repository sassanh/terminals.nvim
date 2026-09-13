local logic = require("terminals.logic")

describe("tab scroll", function()
  local original_columns
  local original_lines
  local original_getmousepos
  local original_navigate
  local original_input_mouse

  before_each(function()
    original_columns = vim.o.columns
    original_lines = vim.o.lines
    original_getmousepos = vim.fn.getmousepos
    original_navigate = logic.navigate
    original_input_mouse = vim.api.nvim_input_mouse
    logic.tab_scroll_cooldown_ms = 150
    logic._last_tab_scroll_ms = nil
  end)

  after_each(function()
    vim.o.columns = original_columns
    vim.o.lines = original_lines
    vim.fn.getmousepos = original_getmousepos
    logic.navigate = original_navigate
    vim.api.nvim_input_mouse = original_input_mouse
    logic.tab_scroll_cooldown_ms = 150
    logic._last_tab_scroll_ms = nil
    if logic.border_window ~= nil and vim.api.nvim_win_is_valid(logic.border_window) then
      vim.api.nvim_win_close(logic.border_window, true)
    end
    if logic.terminal_window ~= nil and vim.api.nvim_win_is_valid(logic.terminal_window) then
      vim.api.nvim_win_close(logic.terminal_window, true)
    end
    logic.border_window = nil
    logic.terminal_window = nil
    logic.current_layout = nil
  end)

  local function open_border()
    vim.o.columns = 200
    vim.o.lines = 40
    local layout = logic.compute_window_layout(nil, nil, nil, nil, 1)
    local border_buffer = vim.api.nvim_create_buf(false, true)
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

  describe("is_mouse_on_tab_bar", function()
    it("is true for all three tab-bar rows", function()
      local _, border_window = open_border()
      for _, line in ipairs({ 1, 2, 3 }) do
        vim.fn.getmousepos = function()
          return { winid = border_window, line = line, wincol = 10 }
        end
        assert.is_true(logic.is_mouse_on_tab_bar())
      end
    end)

    it("is true on padding between tabs", function()
      local layout, border_window = open_border()
      local header_start = layout.header_left_pad + (layout.margin and 1 or 0) + 1
      vim.fn.getmousepos = function()
        return { winid = border_window, line = 2, wincol = header_start }
      end
      assert.is_true(logic.is_mouse_on_tab_bar())
      assert.is_nil(logic.border_tab_under_mouse())
    end)

    it("is false outside the tab bar", function()
      local _, border_window = open_border()
      vim.fn.getmousepos = function()
        return { winid = border_window, line = 4, wincol = 10 }
      end
      assert.is_false(logic.is_mouse_on_tab_bar())
      vim.fn.getmousepos = function()
        return { winid = 999999, line = 2, wincol = 10 }
      end
      assert.is_false(logic.is_mouse_on_tab_bar())
    end)

    it("is false without layout or border window", function()
      open_border()
      logic.current_layout = nil
      vim.fn.getmousepos = function()
        return { winid = logic.border_window, line = 2, wincol = 10 }
      end
      assert.is_false(logic.is_mouse_on_tab_bar())
    end)
  end)

  describe("handle_tab_scroll", function()
    it("navigates once per scroll tick", function()
      local _, border_window = open_border()
      local directions = {}
      logic.navigate = function(direction)
        table.insert(directions, direction)
      end
      vim.fn.getmousepos = function()
        return { winid = border_window, line = 2, wincol = 10 }
      end
      assert.is_true(logic.handle_tab_scroll(1, 1000))
      assert.same({ 1 }, directions)
      assert.is_true(logic.handle_tab_scroll(-1, 2000))
      assert.same({ 1, -1 }, directions)
    end)

    it("throttles fast scrolls so tabs change slowly", function()
      local _, border_window = open_border()
      local directions = {}
      logic.navigate = function(direction)
        table.insert(directions, direction)
      end
      vim.fn.getmousepos = function()
        return { winid = border_window, line = 2, wincol = 10 }
      end
      assert.is_true(logic.handle_tab_scroll(1, 1000))
      assert.is_true(logic.handle_tab_scroll(1, 1050))
      assert.same({ 1 }, directions)
      assert.is_true(logic.handle_tab_scroll(1, 1000 + logic.tab_scroll_cooldown_ms))
      assert.same({ 1, 1 }, directions)
    end)

    it("returns false when the mouse is not on the tab bar", function()
      open_border()
      local called = false
      logic.navigate = function()
        called = true
      end
      vim.fn.getmousepos = function()
        return { winid = 999999, line = 2, wincol = 10 }
      end
      assert.is_false(logic.handle_tab_scroll(1, 1000))
      assert.is_false(called)
    end)
  end)

  describe("_handle_scroll", function()
    it("swallows throttled scrolls on the tab bar", function()
      local _, border_window = open_border()
      local navigations = 0
      logic.navigate = function()
        navigations = navigations + 1
      end
      local forwarded = 0
      local original_feedkeys = vim.api.nvim_feedkeys
      vim.api.nvim_feedkeys = function()
        forwarded = forwarded + 1
      end
      vim.fn.getmousepos = function()
        return { winid = border_window, line = 2, wincol = 10, screenrow = 5, screencol = 10 }
      end
      logic._handle_scroll("up", -1)
      logic._handle_scroll("up", -1)
      vim.api.nvim_feedkeys = original_feedkeys
      assert.equals(1, navigations)
      assert.equals(0, forwarded)
    end)

    it("forwards scrolls outside the tab bar", function()
      open_border()
      local navigations = 0
      logic.navigate = function()
        navigations = navigations + 1
      end
      local forwarded = nil
      local original_feedkeys = vim.api.nvim_feedkeys
      vim.api.nvim_feedkeys = function(keys, mode, escape)
        forwarded = { keys = keys, mode = mode }
      end
      vim.fn.getmousepos = function()
        return { winid = 999999, line = 2, wincol = 10, screenrow = 7, screencol = 12 }
      end
      logic._handle_scroll("down", 1)
      vim.api.nvim_feedkeys = original_feedkeys
      assert.equals(0, navigations)
      assert.is_not_nil(forwarded)
      assert.equals("n", forwarded.mode)
      assert.is_true(forwarded.keys:find("ScrollWheelDown") ~= nil or #forwarded.keys > 0)
    end)
  end)

  describe("keymaps", function()
    it("registers global and buffer-local scroll mappings", function()
      require("terminals").setup()
      for _, lhs in ipairs({ "<ScrollWheelUp>", "<ScrollWheelDown>", "<ScrollWheelLeft>", "<ScrollWheelRight>" }) do
        assert.not_equals("", vim.fn.maparg(lhs, "n"), "missing global mapping for " .. lhs)
      end
      local buffer = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buffer)
      logic.leave_terminal()
      local modes = { t = {}, n = {} }
      for _, mode in ipairs({ "t", "n" }) do
        for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(buffer, mode)) do
          modes[mode][keymap.lhs] = true
        end
      end
      for _, lhs in ipairs({ "<ScrollWheelUp>", "<ScrollWheelDown>", "<ScrollWheelLeft>", "<ScrollWheelRight>" }) do
        assert.is_true(modes.t[lhs] == true, "missing t mapping for " .. lhs)
        assert.is_true(modes.n[lhs] == true, "missing n mapping for " .. lhs)
      end
    end)
  end)
end)
