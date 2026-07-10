-- demo workspace: a tiny lua module with no personal data

local M = {}

function M.greet(name)
  return "hello, " .. name
end

return M