# pi-nvim

Bridge between [pi](https://github.com/badlogic/pi) coding agent and Neovim. Run pi in one terminal pane and Neovim in another — send files, selections, and prompts from Neovim directly into your running pi session.

> **Fork notice** — this checkout is published as `@sergioia-dev/pi-nvim`, a fork of
> [carderne/pi-nvim](https://github.com/carderne/pi-nvim). Compared to the upstream npm
> release it forwards prompt options and images, hardens the socket bridge (stale-manifest
> pruning, `0700` sockets directory, `0600` sockets) and accepts arguments on `:Pi`/`:PiSend`.
> The Neovim half is unchanged; only the pi extension name differs.

![demo](./demo/demo.gif)

## How it works

The repo contains two components:

1. **Pi extension** (`index.ts`) — opens a unix socket when pi starts. External tools can send JSON messages to inject prompts into the active pi session.
2. **Neovim plugin** (`lua/pi-nvim/`) — connects to that socket via libuv. Sends context from your editor to pi.

Discovery is automatic: the extension writes socket info to `/tmp/pi-nvim-sockets/`, and the Neovim plugin scans that directory, preferring sessions matching your cwd.

On Windows, unix sockets don't exist, so the extension binds a named pipe (`\\.\pipe\pi-nvim-*`) and writes the manifests into `%TEMP%/pi-nvim-sockets/` instead — the plugin reads the actual connect address from the manifest's `socket` field. Unix behavior is unchanged.

## Install

### Pi side

```bash
pi install npm:@sergioia-dev/pi-nvim
```

Or add to `~/.pi/agent/settings.json`:

```json
{
  "packages": ["https://github.com/sergioia-dev/pi-nvim"]
}
```

Then `/reload` in pi.

### Neovim side

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "sergioia-dev/pi-nvim" }
```

Then in your config:

```lua
require("pi-nvim").setup()
```

Options (defaults):

```lua
require("pi-nvim").setup({
  socket_path = nil, -- auto-discover
  set_default_keymaps = true,
  notify = true, -- popup when pi finishes a task or the session stops
})
```

## Usage

Start pi in one terminal. Start Neovim in another. The pi extension automatically opens a socket on session start.

Neovim keeps one connection open and shows a `vim.notify` popup when pi finishes a task or the session stops (set `notify = false` to silence it).

### Commands

| Command | Description |
|---|---|
| `:Pi` | Open the Send to pi dialog (works in normal and visual mode) |
| `:PiSend` | Type a prompt and send to pi |
| `:PiSendFile` | Send current file path + prompt |
| `:PiSendSelection` | Send visual selection + prompt |
| `:PiSendBuffer` | Send entire buffer + prompt |
| `:PiPing` | Check if pi is reachable |
| `:PiSessions` | List/switch between running pi sessions |

### Default keybindings

`<leader>p` is mapped to `:Pi` in both normal and visual mode by default.

To disable the default mappings:

```lua
require("pi-nvim").setup({
  set_default_keymaps = false,
})
```

### The `:Pi` dialog

Opens a floating window in the center of the screen:

- Shows the current **file name** (always sent)
- If you had a **visual selection**, it shows the line range and sends the selected text
- If no selection, you can press **Tab** to toggle sending the **entire buffer**
- Type a prompt and press **Enter** to send (or just Enter with no prompt)
- Press **Esc** or **Ctrl-C** to cancel

### Additional keybindings

```lua
vim.keymap.set("n", "<leader>pp", ":PiSend<CR>")
vim.keymap.set("n", "<leader>pf", ":PiSendFile<CR>")
vim.keymap.set("v", "<leader>ps", ":PiSendSelection<CR>")
vim.keymap.set("n", "<leader>pb", ":PiSendBuffer<CR>")
vim.keymap.set("n", "<leader>pi", ":PiPing<CR>")
```

## Protocol

The socket accepts newline-delimited JSON:

```json
{"type": "prompt", "message": "your prompt here"}
{"type": "ping"}
```

Responses:

```json
{"ok": true}
{"ok": true, "type": "pong"}
{"ok": false, "error": "..."}
```

This means you can also send prompts from any tool:

```bash
echo '{"type":"prompt","message":"hello"}' | socat - UNIX-CONNECT:/tmp/pi-nvim-sockets/<hash>.sock
```

## License

MIT
