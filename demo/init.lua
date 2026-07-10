vim.opt.number = true
vim.opt.relativenumber = false
vim.opt.showmode = false
vim.opt.laststatus = 3
vim.opt.cmdheight = 0
vim.opt.signcolumn = "no"

vim.g.mapleader = " "
vim.g.maplocalleader = " "

vim.cmd.colorscheme("habamax")

local repo_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(repo_root)

local logic = require("terminals.logic")

require("terminals").setup()

local function open_slot(id, args)
  logic.activate_terminal({
    id = id,
    toggle = false,
    append_mode = true,
    args = args,
  })
end

local function with_job(id, callback)
  vim.defer_fn(function()
    local buf = vim.fn.bufnr("term://Terminal-" .. id)
    if buf == -1 then
      return
    end
    local ok, job_id = pcall(vim.api.nvim_buf_get_var, buf, "terminal_job_id")
    if ok and job_id then
      callback(job_id)
    end
  end, 700)
end

local function send(job_id, text)
  vim.fn.chansend(job_id, text)
end

local function type_command(id, command)
  with_job(id, function(job_id)
    send(job_id, "export PS1='demo$ '\r")

    local index = 1
    local function type_next()
      if index > #command then
        send(job_id, "\r")
        return
      end
      send(job_id, command:sub(index, index))
      index = index + 1
      vim.defer_fn(type_next, 45)
    end

    vim.defer_fn(type_next, 300)
  end)
end

local function revisit(id)
  logic.activate_terminal({ id = id, toggle = false, append_mode = true })
end

vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    vim.cmd.edit(repo_root .. "/demo/project/main.lua")

    vim.defer_fn(function()
      open_slot(1, "/bin/sh")
      type_command(1, 'echo "This is terminal 1"')
    end, 500)

    vim.defer_fn(function()
      open_slot(2, "/bin/sh")
      type_command(2, 'echo "This is terminal 2"')
    end, 3800)

    vim.defer_fn(function()
      open_slot(3, repo_root .. "/demo/watch.sh")
    end, 7100)

    vim.defer_fn(function()
      open_slot(4, repo_root .. "/demo/monitor.sh")
    end, 9400)

    vim.defer_fn(function()
      revisit(1)
    end, 11200)

    vim.defer_fn(function()
      revisit(2)
    end, 12700)

    vim.defer_fn(function()
      revisit(3)
    end, 14200)

    vim.defer_fn(function()
      revisit(4)
    end, 15700)

    vim.defer_fn(function()
      revisit(1)
    end, 17200)
  end,
})