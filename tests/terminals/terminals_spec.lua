local plugin = require("terminals")

describe("setup", function()
  it("works with default", function()
    assert("activate_terminal", plugin.activate_terminal())
  end)
end)
