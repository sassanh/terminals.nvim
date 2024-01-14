-- main module file
local logic = require("terminals.logic")

---@class Config
local config = {}

---@class Terminals
---@field group number
local M = {}

---@type Config
M.config = config

---@param args Config?
M.setup = function(args)
  M.config = vim.tbl_deep_extend("force", M.config, args or {})

  vim.api.nvim_create_autocmd("TermOpen", {
    group = M.group,
    pattern = "*",
    callback = function()
      logic.leave_terminal()
    end,
  })
  vim.api.nvim_create_autocmd("TermEnter", {
    group = M.group,
    pattern = "*",
    callback = function()
      vim.opt_local.scrolloff = 0
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = M.group,
    pattern = "term://Terminal-*",
    callback = function(options)
      logic.terminal_window_closed(options.file)
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = M.group,
    pattern = "*",
    callback = logic.handle_resize,
  })

  vim.keymap.set("n", "<d-h>", function()
    logic.save_terminal_state(false)
    logic.navigate(-1)
  end, { silent = true })
  vim.keymap.set("n", "<d-l>", function()
    logic.save_terminal_state(false)
    logic.navigate(1)
  end, { silent = true })
  vim.keymap.set("n", "<d-s-h>", function()
    logic.move_terminal(-1)
  end, { silent = true })
  vim.keymap.set("n", "<d-s-l>", function()
    logic.move_terminal(1)
  end, { silent = true })

  vim.keymap.set("n", "<d-/>", "?")
  vim.keymap.set("i", "<d-/>", "<c-c>?")

  vim.keymap.set("n", "<d-bs>", function()
    logic.save_terminal_state(false)
    logic.toggle_terminal()
  end, { silent = true })
end

M.group = vim.api.nvim_create_augroup("Terminal", { clear = true })

--- @param opts ActivateTerminalOptions|nil
function M.activate_terminal(opts)
  logic.activate_terminal(opts)
end

return M
