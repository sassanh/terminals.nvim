# terminals.nvim

<p align="center">
  <img src="assets/hero.gif" alt="terminals.nvim demo with tab-style terminal slots" width="900">
</p>

![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/sassanh/terminals.nvim/lint-test.yml?branch=main&style=for-the-badge)
![Lua](https://img.shields.io/badge/Made%20with%20Lua-blueviolet.svg?style=for-the-badge&logo=lua)

A terminal manager for Neovim with up to 10 persistent terminal slots, a tab-style header, and keyboard-driven navigation.

## Requirements

- Neovim >= 0.8.0
- macOS (default keymaps use the `<D-…>` Cmd modifier)

## Installation

### lazy.nvim

```lua
{
  "sassanh/terminals.nvim",
  config = function()
    require("terminals").setup()
  end,
}
```

### packer.nvim

```lua
use {
  "sassanh/terminals.nvim",
  config = function()
    require("terminals").setup()
  end,
}
```

### LuaRocks

```sh
luarocks install terminals.nvim
```

## Setup

Call `setup()` to register keymaps and autocmds:

```lua
require("terminals").setup()
```

## Default Keymaps

| Keymap | Action |
| --- | --- |
| `<D-0>` … `<D-9>` | Open or switch to terminal slot 0–9 |
| `<D-BS>` | Toggle the terminal window |
| `<D-h>` / `<D-l>` | Move left/right between terminals |
| `<D-S-h>` / `<D-S-l>` | Move the terminal buffer left/right |
| `<D-i>` | Enter terminal input mode (all keys go to the shell) |
| `<D-S-i>` | Leave terminal input mode |
| `<D-[>` | Leave terminal mode |
| `<D-/>` / `<D-?>` | Backward search in the terminal buffer |
| `<D-p>` / `<D-S-p>` | Paste with `p` or `P` in the terminal buffer |

## Configuration

All keymaps are configurable:

```lua
require("terminals").setup({
  keys = {
    go_left = "<D-h>",
    go_right = "<D-l>",
    move_left = "<D-S-h>",
    move_right = "<D-S-l>",
    toggle = "<D-BS>",
    toggle_reverse_search = "<D-/>",
    focus = "<D-i>",
    unfocus = "<D-S-i>",
    leave = "<D-[>",
    paste = "<D-p>",
    paste_in_place = "<D-S-p>",
    modifier = "D",
  },
  preserved_keys = {},
})
```

`modifier` is used to build the `<D-0>` … `<D-9>` slot keymaps. Set it to match your platform's super/meta modifier (for example `"D"` on macOS).

`preserved_keys` lets you keep specific terminal-mode keymaps when leaving input mode.

## Commands

- `:Terminal [cmd]` — open a terminal, optionally running `cmd`
- `:ToggleTerminal` — toggle the terminal window
- `:CloseTerminal` — close the terminal window

## API

```lua
require("terminals").activate_terminal({ id = 1 })
```

Options:

- `id` — terminal slot (0–9)
- `toggle` — toggle if already on the same slot (default: `true`)
- `append_mode` — start in insert mode (default: `true`)
- `args` — shell command to run when creating a new terminal

New terminals use your default shell unless `args` is passed or `shell` is set in `setup()`.

```lua
require("terminals").setup({
  shell = "/bin/bash",
})
```