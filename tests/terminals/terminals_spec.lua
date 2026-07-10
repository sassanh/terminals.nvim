local plugin = require("terminals")

describe("terminals", function()
  it("exports activate_terminal", function()
    assert.is_function(plugin.activate_terminal)
  end)

  it("has default keymaps", function()
    assert.equals("<d-bs>", plugin.config.keys.toggle)
    assert.equals("d", plugin.config.keys.modifier)
    assert.equals("<d-h>", plugin.config.keys.go_left)
  end)

  describe("setup", function()
    it("merges custom keys into config", function()
      plugin.setup({
        keys = {
          toggle = "<d-t>",
          go_left = "<d-j>",
        },
      })
      assert.equals("<d-t>", plugin.config.keys.toggle)
      assert.equals("<d-j>", plugin.config.keys.go_left)
      assert.equals("<d-l>", plugin.config.keys.go_right)
    end)

    it("registers normal-mode keymaps", function()
      plugin.setup()
      assert.not_equals("", vim.fn.maparg(plugin.config.keys.toggle, "n"))
      assert.not_equals("", vim.fn.maparg(plugin.config.keys.go_left, "n"))
      assert.not_equals("", vim.fn.maparg(plugin.config.keys.go_right, "n"))
    end)

    it("registers slot keymaps for terminals 0-9", function()
      plugin.setup()
      for i = 0, 9 do
        local key = ("<%s-%s>"):format(plugin.config.keys.modifier, i)
        assert.not_equals("", vim.fn.maparg(key, "n"), "missing keymap for " .. key)
      end
    end)
  end)
end)