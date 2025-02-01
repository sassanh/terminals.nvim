-- main module file
local logic = require("terminals.logic")

---@class Keymap
---@field go_left string
---@field go_right string
---@field move_left string
---@field move_right string
---@field toggle string
---@field toggle_reverse_search string
---@field focus string
---@field unfocus string
---@field leave string
---@field paste string
---@field paste_in_place string
---@field modifier string

---@class TerminalsConfig
---@field keys Keymap
---@field preserved_keys string[]
local config = {
  keys = {
    go_left = "<d-h>",
    go_right = "<d-l>",
    move_left = "<d-s-h>",
    move_right = "<d-s-l>",
    toggle = "<d-bs>",
    toggle_reverse_search = "<d-/>",
    focus = "<d-i>",
    unfocus = "<d-s-i>",
    leave = "<d-[>",
    paste = "<d-p>",
    paste_in_place = "<d-s-p>",
    modifier = "d",
  },
  preserved_keys = {},
}

---@class Terminals
---@field group number
local M = {}

---@type TerminalsConfig
M.config = config

---@param args TerminalsConfig?
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

  vim.keymap.set("n", M.config.keys.go_left, function()
    logic.save_terminal_state(false)
    logic.navigate(-1)
  end, { silent = true })
  vim.keymap.set("n", M.config.keys.go_right, function()
    logic.save_terminal_state(false)
    logic.navigate(1)
  end, { silent = true })
  vim.keymap.set("n", M.config.keys.move_left, function()
    logic.move_terminal(-1)
  end, { silent = true })
  vim.keymap.set("n", M.config.keys.move_right, function()
    logic.move_terminal(1)
  end, { silent = true })

  vim.keymap.set("n", M.config.keys.toggle_reverse_search, "?")
  vim.keymap.set("i", M.config.keys.toggle_reverse_search, "<c-c>?")

  vim.keymap.set("n", M.config.keys.toggle, function()
    logic.save_terminal_state(false)
    logic.toggle_terminal()
  end, { silent = true })

  for i = 0, 9 do
    vim.keymap.set("n", ("<%s-%s>"):format(M.config.keys.modifier, i), function()
      require("terminals.logic").save_terminal_state(false)
      require("terminals.logic").activate_terminal({ id = i })
    end, { silent = true })
  end
end

M.group = vim.api.nvim_create_augroup("Terminal", { clear = true })

--- @param opts ActivateTerminalOptions|nil
function M.activate_terminal(opts)
  logic.activate_terminal(opts)
end

return M
