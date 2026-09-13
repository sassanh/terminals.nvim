local logic = require("terminals.logic")

describe("tab click", function()
  local original_columns
  local original_lines
  local original_getmousepos
  local original_activate

  before_each(function()
    original_columns = vim.o.columns
    original_lines = vim.o.lines
    original_getmousepos = vim.fn.getmousepos
    original_activate = logic.activate_terminal
  end)

  after_each(function()
    vim.o.columns = original_columns
    vim.o.lines = original_lines
    vim.fn.getmousepos = original_getmousepos
    logic.activate_terminal = original_activate
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

  describe("tab_id_at_header_index", function()
    it("maps every tab in a full header", function()
      vim.o.columns = 200
      vim.o.lines = 40
      local layout = logic.compute_window_layout(nil, nil, nil, nil, 1)
      local cell_width = layout.tab_padding * 2 + 4
      for cell = 0, 9 do
        local expected = (cell + 1) % 10
        local digit_index = 1 + cell * cell_width + layout.tab_padding + 1
        assert.equals(expected, logic.tab_id_at_header_index(layout.header2, layout.tab_padding, digit_index))
        local left_edge = 1 + cell * cell_width
        assert.equals(expected, logic.tab_id_at_header_index(layout.header2, layout.tab_padding, left_edge))
        local separator = 1 + (cell + 1) * cell_width - 1
        assert.equals(expected, logic.tab_id_at_header_index(layout.header2, layout.tab_padding, separator))
      end
    end)

    it("ignores the leading border and out-of-range indexes", function()
      vim.o.columns = 200
      vim.o.lines = 40
      local layout = logic.compute_window_layout(nil, nil, nil, nil, 1)
      assert.is_nil(logic.tab_id_at_header_index(layout.header2, layout.tab_padding, 0))
      assert.is_nil(logic.tab_id_at_header_index(layout.header2, layout.tab_padding, -1))
      assert.is_nil(logic.tab_id_at_header_index(layout.header2, layout.tab_padding, vim.fn.strcharlen(layout.header2)))
    end)

    it("maps visible tabs in a left-truncated header", function()
      vim.o.columns = 40
      vim.o.lines = 40
      local layout = logic.compute_window_layout(30, 30, nil, nil, 1)
      assert.equals("┤", vim.fn.strcharpart(layout.header2, 0, 1))
      local length = vim.fn.strcharlen(layout.header2)
      for index = 0, length - 1 do
        local char = vim.fn.strcharpart(layout.header2, index, 1)
        if char:match("%d") then
          assert.equals(tonumber(char), logic.tab_id_at_header_index(layout.header2, layout.tab_padding, index))
        end
      end
      assert.is_nil(logic.tab_id_at_header_index(layout.header2, layout.tab_padding, length - 1))
    end)

    it("maps visible tabs in a right-truncated header", function()
      vim.o.columns = 40
      vim.o.lines = 40
      local layout = logic.compute_window_layout(30, 30, nil, nil, 6)
      assert.not_equals("┤", vim.fn.strcharpart(layout.header2, 0, 1))
      local length = vim.fn.strcharlen(layout.header2)
      for index = 0, length - 1 do
        local char = vim.fn.strcharpart(layout.header2, index, 1)
        if char:match("%d") then
          assert.equals(tonumber(char), logic.tab_id_at_header_index(layout.header2, layout.tab_padding, index))
        end
      end
      assert.is_nil(logic.tab_id_at_header_index(layout.header2, layout.tab_padding, 0))
    end)
  end)

  describe("tab_id_for_border_click", function()
    it("maps clicks on all three tab rows", function()
      vim.o.columns = 200
      vim.o.lines = 40
      local layout = logic.compute_window_layout(nil, nil, nil, nil, 1)
      local cell_width = layout.tab_padding * 2 + 4
      local header_start = layout.header_left_pad + (layout.margin and 1 or 0) + 1
      for cell = 0, 9 do
        local expected = (cell + 1) % 10
        local digit_relative = 1 + cell * cell_width + layout.tab_padding + 1
        local wincol = header_start + digit_relative
        for _, row in ipairs({ 1, 2, 3 }) do
          assert.equals(expected, logic.tab_id_for_border_click(row, wincol, layout))
        end
      end
    end)

    it("ignores clicks outside the tab bar", function()
      vim.o.columns = 200
      vim.o.lines = 40
      local layout = logic.compute_window_layout(nil, nil, nil, nil, 1)
      local header_start = layout.header_left_pad + (layout.margin and 1 or 0) + 1
      assert.is_nil(logic.tab_id_for_border_click(4, header_start + 5, layout))
      assert.is_nil(logic.tab_id_for_border_click(0, header_start + 5, layout))
      assert.is_nil(logic.tab_id_for_border_click(2, 1, layout))
      assert.is_nil(logic.tab_id_for_border_click(2, layout.width + 10, layout))
    end)
  end)

  describe("compute_window_layout header padding", function()
    it("centers the header within the available width", function()
      vim.o.columns = 200
      vim.o.lines = 40
      local layout = logic.compute_window_layout(nil, nil, nil, nil, 1)
      local available = layout.width - (layout.margin and 2 or 0)
      assert.equals(available, layout.header_left_pad + vim.fn.strcharlen(layout.header1) + layout.header_right_pad)
      assert.is_true(math.abs(layout.header_left_pad - layout.header_right_pad) <= 1)
    end)
  end)

  describe("handle_tab_click", function()
    it("activates the clicked tab without toggling", function()
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

      local captured = nil
      logic.activate_terminal = function(opts)
        captured = opts
      end
      local cell_width = layout.tab_padding * 2 + 4
      local digit_relative = 1 + 2 * cell_width + layout.tab_padding + 1
      local wincol = layout.header_left_pad + (layout.margin and 1 or 0) + 1 + digit_relative
      vim.fn.getmousepos = function()
        return { winid = border_window, line = 2, wincol = wincol }
      end

      logic.handle_tab_click()

      assert.is_not_nil(captured)
      assert.equals(3, captured.id)
      assert.equals(false, captured.toggle)
    end)

    it("ignores clicks outside the tab bar", function()
      vim.o.columns = 200
      vim.o.lines = 40
      local layout = logic.compute_window_layout(nil, nil, nil, nil, 1)
      local border_buffer = vim.api.nvim_create_buf(false, true)
      logic.border_window = vim.api.nvim_open_win(border_buffer, false, {
        relative = "editor",
        row = 0,
        col = 0,
        width = 20,
        height = 5,
      })
      logic.current_layout = layout

      local captured = nil
      logic.activate_terminal = function(opts)
        captured = opts
      end
      vim.fn.getmousepos = function()
        return { winid = logic.border_window, line = 5, wincol = 5 }
      end
      logic.handle_tab_click()
      assert.is_nil(captured)

      vim.fn.getmousepos = function()
        return { winid = 999999, line = 2, wincol = 10 }
      end
      logic.handle_tab_click()
      assert.is_nil(captured)
    end)
  end)

  describe("border_tab_under_mouse", function()
    it("returns the tab id under the mouse", function()
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
      local cell_width = layout.tab_padding * 2 + 4
      local digit_relative = 1 + 2 * cell_width + layout.tab_padding + 1
      local wincol = layout.header_left_pad + (layout.margin and 1 or 0) + 1 + digit_relative
      vim.fn.getmousepos = function()
        return { winid = border_window, line = 2, wincol = wincol }
      end
      assert.equals(3, logic.border_tab_under_mouse())
    end)

    it("returns nil when the mouse is not on a tab", function()
      vim.o.columns = 200
      vim.o.lines = 40
      local layout = logic.compute_window_layout(nil, nil, nil, nil, 1)
      local border_buffer = vim.api.nvim_create_buf(false, true)
      logic.border_window = vim.api.nvim_open_win(border_buffer, false, {
        relative = "editor",
        row = 0,
        col = 0,
        width = 20,
        height = 5,
      })
      logic.current_layout = layout
      vim.fn.getmousepos = function()
        return { winid = 999999, line = 2, wincol = 10 }
      end
      assert.is_nil(logic.border_tab_under_mouse())
    end)
  end)

  describe("terminal_window_closed", function()
    local function open_floats()
      local terminal_buffer = vim.api.nvim_create_buf(false, true)
      logic.terminal_window = vim.api.nvim_open_win(terminal_buffer, false, {
        relative = "editor",
        row = 10,
        col = 10,
        width = 20,
        height = 5,
      })
      local border_buffer = vim.api.nvim_create_buf(false, true)
      logic.border_window = vim.api.nvim_open_win(border_buffer, false, {
        relative = "editor",
        row = 0,
        col = 0,
        width = 20,
        height = 5,
      })
    end

    it("closes the windows when leaving the terminal elsewhere", function()
      vim.o.columns = 200
      vim.o.lines = 40
      logic.current_layout = logic.compute_window_layout(nil, nil, nil, nil, 1)
      open_floats()
      vim.fn.getmousepos = function()
        return { winid = 999999, line = 2, wincol = 10 }
      end
      logic.terminal_window_closed("term://Terminal-2")
      assert.is_false(vim.api.nvim_win_is_valid(logic.terminal_window))
      assert.is_false(vim.api.nvim_win_is_valid(logic.border_window))
    end)

    it("keeps the windows open when leaving toward a border tab", function()
      vim.o.columns = 200
      vim.o.lines = 40
      local layout = logic.compute_window_layout(nil, nil, nil, nil, 1)
      logic.current_layout = layout
      open_floats()
      local cell_width = layout.tab_padding * 2 + 4
      local digit_relative = 1 + 2 * cell_width + layout.tab_padding + 1
      local wincol = layout.header_left_pad + (layout.margin and 1 or 0) + 1 + digit_relative
      local border_window = logic.border_window
      vim.fn.getmousepos = function()
        return { winid = border_window, line = 2, wincol = wincol }
      end
      logic.terminal_window_closed("term://Terminal-2")
      assert.is_true(vim.api.nvim_win_is_valid(logic.terminal_window))
      assert.is_true(vim.api.nvim_win_is_valid(logic.border_window))
    end)

    it("ignores non-terminal buffers", function()
      vim.o.columns = 200
      vim.o.lines = 40
      logic.current_layout = logic.compute_window_layout(nil, nil, nil, nil, 1)
      open_floats()
      vim.fn.getmousepos = function()
        return { winid = 999999, line = 2, wincol = 10 }
      end
      logic.terminal_window_closed("some-file.txt")
      assert.is_true(vim.api.nvim_win_is_valid(logic.terminal_window))
      assert.is_true(vim.api.nvim_win_is_valid(logic.border_window))
    end)
  end)

  describe("toggle_terminal", function()
    it("closes both windows without reactivating when the mouse hovers the tabs", function()
      require("terminals").setup()
      vim.o.columns = 200
      vim.o.lines = 40
      local layout = logic.compute_window_layout(nil, nil, nil, nil, 1)
      logic.current_layout = layout
      local terminal_buffer = vim.api.nvim_create_buf(false, true)
      logic.terminal_window = vim.api.nvim_open_win(terminal_buffer, false, {
        relative = "editor",
        row = 10,
        col = 10,
        width = 20,
        height = 5,
      })
      local border_buffer = vim.api.nvim_create_buf(false, true)
      logic.border_window = vim.api.nvim_open_win(border_buffer, false, {
        relative = "editor",
        row = 0,
        col = 0,
        width = 20,
        height = 5,
      })
      local cell_width = layout.tab_padding * 2 + 4
      local digit_relative = 1 + 2 * cell_width + layout.tab_padding + 1
      local wincol = layout.header_left_pad + (layout.margin and 1 or 0) + 1 + digit_relative
      local border_window = logic.border_window
      vim.fn.getmousepos = function()
        return { winid = border_window, line = 2, wincol = wincol }
      end

      local captured = nil
      logic.activate_terminal = function(opts)
        captured = opts
      end
      vim.api.nvim_set_current_win(logic.border_window)
      captured = nil
      vim.api.nvim_set_current_win(logic.terminal_window)

      logic.toggle_terminal()

      assert.is_nil(captured)
      assert.is_false(vim.api.nvim_win_is_valid(logic.terminal_window))
      assert.is_false(vim.api.nvim_win_is_valid(logic.border_window))
    end)
  end)

  describe("on_win_enter", function()
    it("activates the clicked tab when the border window is entered", function()
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
      vim.api.nvim_set_current_win(border_window)

      local captured = nil
      logic.activate_terminal = function(opts)
        captured = opts
      end
      local cell_width = layout.tab_padding * 2 + 4
      local digit_relative = 1 + 2 * cell_width + layout.tab_padding + 1
      local wincol = layout.header_left_pad + (layout.margin and 1 or 0) + 1 + digit_relative
      vim.fn.getmousepos = function()
        return { winid = border_window, line = 2, wincol = wincol }
      end

      logic.on_win_enter()

      assert.is_not_nil(captured)
      assert.equals(3, captured.id)
      assert.equals(false, captured.toggle)
    end)

    it("ignores entering other windows", function()
      vim.o.columns = 200
      vim.o.lines = 40
      local layout = logic.compute_window_layout(nil, nil, nil, nil, 1)
      local border_buffer = vim.api.nvim_create_buf(false, true)
      logic.border_window = vim.api.nvim_open_win(border_buffer, false, {
        relative = "editor",
        row = 0,
        col = 0,
        width = 20,
        height = 5,
      })
      logic.current_layout = layout
      local other_buffer = vim.api.nvim_create_buf(false, true)
      local other_window = vim.api.nvim_open_win(other_buffer, false, {
        relative = "editor",
        row = 10,
        col = 10,
        width = 20,
        height = 5,
      })
      vim.api.nvim_set_current_win(other_window)

      local captured = nil
      logic.activate_terminal = function(opts)
        captured = opts
      end
      vim.fn.getmousepos = function()
        return { winid = logic.border_window, line = 2, wincol = 10 }
      end

      logic.on_win_enter()
      assert.is_nil(captured)
      vim.api.nvim_win_close(other_window, true)
    end)

    it("ignores border entry while switching terminals", function()
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
      vim.api.nvim_set_current_win(border_window)
      logic.switching_terminals = true

      local captured = nil
      logic.activate_terminal = function(opts)
        captured = opts
      end
      vim.fn.getmousepos = function()
        return { winid = border_window, line = 2, wincol = 10 }
      end

      logic.on_win_enter()
      assert.is_nil(captured)
      logic.switching_terminals = false
    end)

    it("ignores keyboard entry without the mouse on the border", function()
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
      vim.api.nvim_set_current_win(border_window)

      local captured = nil
      logic.activate_terminal = function(opts)
        captured = opts
      end
      vim.fn.getmousepos = function()
        return { winid = 999999, line = 2, wincol = 10 }
      end

      logic.on_win_enter()
      assert.is_nil(captured)
    end)

    it("fires through the registered WinEnter autocmd on real window entry", function()
      require("terminals").setup()
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

      local captured = nil
      logic.activate_terminal = function(opts)
        captured = opts
      end
      local cell_width = layout.tab_padding * 2 + 4
      local digit_relative = 1 + 2 * cell_width + layout.tab_padding + 1
      local wincol = layout.header_left_pad + (layout.margin and 1 or 0) + 1 + digit_relative
      vim.fn.getmousepos = function()
        return { winid = border_window, line = 2, wincol = wincol }
      end

      vim.api.nvim_set_current_win(border_window)

      assert.is_nil(captured)
    end)

    it("switches via the mouse expr mapping", function()
      require("terminals").setup()
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
      local terminal_buffer = vim.api.nvim_create_buf(false, true)
      logic.terminal_window = vim.api.nvim_open_win(terminal_buffer, false, {
        relative = "editor",
        row = 10,
        col = 10,
        width = 20,
        height = 5,
      })
      vim.api.nvim_set_current_win(logic.terminal_window)

      local cell_width = layout.tab_padding * 2 + 4
      local digit_relative = 1 + 2 * cell_width + layout.tab_padding + 1
      local wincol = layout.header_left_pad + (layout.margin and 1 or 0) + 1 + digit_relative
      vim.fn.getmousepos = function()
        return { winid = border_window, line = 2, wincol = wincol }
      end

      local result = logic._mouse_click_expr("<LeftMouse>")
      assert.equals("", result)
      vim.wait(20)

      -- scheduled activate should have fired
      assert.is_true(vim.api.nvim_win_is_valid(logic.terminal_window))
    end)
  end)

  describe("single gate", function()
    it("activates via the shared gate without manual save", function()
      require("terminals").setup()
      vim.o.columns = 200
      vim.o.lines = 40
      for _, name in ipairs({ "term://Terminal-1", "term://Terminal-2" }) do
        local existing = vim.fn.bufnr(name)
        if existing ~= -1 then
          vim.api.nvim_buf_delete(existing, { force = true })
        end
      end
      logic.terminal_state = {}
      local first = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(first, "term://Terminal-1")
      local second = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(second, "term://Terminal-2")
      local orig_get = vim.api.nvim_get_option_value
      vim.api.nvim_get_option_value = function(name, opts)
        if name == "buftype" and opts and type(opts) == "table" and (opts.buf == first or opts.buf == second) then
          return "terminal"
        end
        if opts == nil then
          return orig_get(name, {})
        end
        return orig_get(name, opts)
      end
      logic.terminal_state[first] = true
      logic.terminal_state[second] = true
      logic.terminal_window = vim.api.nvim_open_win(first, true, {
        relative = "editor",
        row = 10,
        col = 10,
        width = 20,
        height = 5,
      })
      local border_buffer = vim.api.nvim_create_buf(false, true)
      logic.border_window = vim.api.nvim_open_win(border_buffer, false, {
        relative = "editor",
        row = 0,
        col = 0,
        width = 20,
        height = 5,
      })
      logic.current_layout = logic.compute_window_layout(nil, nil, nil, nil, 1)
      logic.last_terminal = 1

      local orig_mode = vim.api.nvim_get_mode
      vim.api.nvim_get_mode = function()
        return { mode = "t", blocking = false }
      end
      logic.activate_terminal({ id = 2, toggle = false })
      vim.api.nvim_get_mode = orig_mode

      vim.api.nvim_get_option_value = orig_get

      assert.equals(2, logic.last_terminal)
      assert.equals(true, logic.terminal_state[first])
      assert.is_true(vim.api.nvim_win_is_valid(logic.terminal_window))
      assert.equals(second, vim.api.nvim_win_get_buf(logic.terminal_window))
    end)
  end)
end)
