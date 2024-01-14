# terminals.nvim

![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/sassanh/terminals.nvim/lint-test.yml?branch=main&style=for-the-badge)
![Lua](https://img.shields.io/badge/Made%20with%20Lua-blueviolet.svg?style=for-the-badge&logo=lua)

A template repository for Neovim plugins.

## Status

This is work in progress, the plugin is working and is serving me for years, but it is not yet packaged as a configurable plugin, so while pro-users should be able to set it up for themselves by checking/modifying the keymaps in the code, it may be tricky for non-pro-users.

## Default Keymaps

`<d-1>` to open a terminal in the first position, `<d-2>` for the second, and so on.
`<d-bs>` to toggle the terminal window.
`<d-h>`/`<d-l>` to move left/right between terminals.
`<d-s-l>`/`<d-s-h>` to move the terminal buffer to the left/right.
`<d-i>` to disable any keybindings in the terminal buffer, you can exit it only with `<d-s-i>`.
`<d-/>`/`<d-?>` to initiate a backward search in the terminal buffer.
`<d-p>`/`<d-s-p>` to paste with `p` or `P` respectively in the terminal buffer.
