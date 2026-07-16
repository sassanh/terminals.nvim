local logic = require("terminals.logic")
local plugin = require("terminals")

describe("layout cycling", function()
  before_each(function()
    logic.layout_index = 1
    plugin.setup({
      layouts = {
        { width = logic.default_width, height = logic.default_height, row = 0 },
        { width = "40%", height = "50%", row = 0, col = "right" },
        { width = 50, height = 20, row = "center", col = "center" },
      },
    })
  end)

  it("resolves the active layout preset", function()
    logic.layout_index = 1
    local w, h, r, c = logic.resolve_active_layout()
    assert.is_function(w)
    assert.is_function(h)
    assert.equals(0, r)
    assert.is_nil(c)

    logic.layout_index = 2
    w, h, r, c = logic.resolve_active_layout()
    assert.equals("40%", w)
    assert.equals("50%", h)
    assert.equals(0, r)
    assert.equals("right", c)
  end)

  it("inherits unset preset fields from top-level config", function()
    plugin.setup({
      width = 90,
      height = 30,
      row = 2,
      col = 4,
      layouts = {
        { width = 40 },
      },
    })

    local w, h, r, c = logic.resolve_active_layout()
    assert.equals(40, w)
    assert.equals(30, h)
    assert.equals(2, r)
    assert.equals(4, c)
  end)

  it("rings through layout presets", function()
    assert.equals(1, logic.layout_index)
    logic.cycle_layout()
    assert.equals(2, logic.layout_index)
    logic.cycle_layout()
    assert.equals(3, logic.layout_index)
    logic.cycle_layout()
    assert.equals(1, logic.layout_index)
  end)

  it("does nothing when layouts are empty", function()
    plugin.setup({ layouts = {} })
    logic.layout_index = 1
    logic.cycle_layout()
    assert.equals(1, logic.layout_index)
  end)

  it("registers the cycle_layout keymap", function()
    plugin.setup()
    assert.not_equals("", vim.fn.maparg(plugin.config.keys.cycle_layout, "n"))
  end)
end)
