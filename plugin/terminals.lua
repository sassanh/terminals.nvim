vim.api.nvim_create_user_command("Terminal", function(options)
  require("terminals.logic").activate_terminal({ args = options.args })
end, { nargs = "*" })
vim.api.nvim_create_user_command("CloseTerminal", require("terminals.logic").close_terminal, { nargs = 0 })
vim.api.nvim_create_user_command("ToggleTerminal", require("terminals.logic").toggle_terminal, { nargs = 0 })
for i = 0, 9 do
  vim.keymap.set("n", ("<d-%s>"):format(i), function()
    require("terminals.logic").save_terminal_state(false)
    require("terminals.logic").activate_terminal({ id = i })
  end, { silent = true })
end
