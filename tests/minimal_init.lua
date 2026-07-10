local root = vim.fn.fnamemodify(".", ":p")
local plenary_dir = root .. "vendor/plenary.nvim"

if vim.fn.isdirectory(plenary_dir) == 0 then
  vim.fn.mkdir(root .. "vendor", "p")
  vim.fn.system({ "git", "clone", "--depth", "1", "https://github.com/nvim-lua/plenary.nvim", plenary_dir })
end

vim.opt.rtp:append(root)
vim.opt.rtp:append(plenary_dir)

vim.cmd("runtime plugin/plenary.vim")
require("plenary.busted")