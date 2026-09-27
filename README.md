# pi-nvim

Bridge between [pi](https://github.com/badlogic/pi) coding agent and Neovim. Run pi in one terminal pane and Neovim in another — send files, selections, and prompts from Neovim directly into your running pi session.

![demo](./demo/demo.gif)

## How it works

The repo contains two components:

1. **Pi extension** (`index.ts`) — opens a unix socket when pi starts. External tools can inject prompts (fire-and-forget) or make RPC calls (request/response) into the active pi session.
2. **Neovim plugin** (`lua/pi-nvim/`) — connects to that socket via libuv. Sends context from your editor to pi, and exposes `request`/`complete`/`capabilities` for other plugins.

Discovery is automatic: the extension writes socket info to `/tmp/pi-nvim-sockets/`, and the Neovim plugin scans that directory, preferring sessions matching your cwd.

On Windows, unix sockets don't exist, so the extension binds a named pipe (`\\.\pipe\pi-nvim-*`) and writes the manifests into `%TEMP%/pi-nvim-sockets/` instead — the plugin reads the actual connect address from the manifest's `socket` field. Unix behavior is unchanged.

## Install

### Pi side

```bash
pi install npm:pi-nvim
```

Or add to `~/.pi/agent/settings.json`:

```json
{
  "packages": ["https://github.com/carderne/pi-nvim"]
}
```

Then `/reload` in pi.

### Neovim side

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "carderne/pi-nvim" }
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
})
```

## Usage

Start pi in one terminal. Start Neovim in another. The pi extension automatically opens a socket on session start.

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

The socket accepts newline-delimited JSON.

### Fire-and-forget

Inject a turn into the active pi session, or check connectivity:

```json
{"type": "prompt", "message": "your prompt here"}
{"type": "ping"}
```

Responses:

```json
{"ok": true}
{"ok": true, "type": "pong"}
```

`prompt` only acknowledges receipt. It does not return the model's reply.

### RPC (request/response)

Ask pi to run a namespaced method and return its result:

```json
{"id": "1", "type": "request", "method": "llm.complete", "params": {"messages": [{"role": "user", "content": "..."}]}}
```

Responses:

```json
{"id": "1", "ok": true, "result": {"text": "...", "model": "..."}}
{"id": "1", "ok": false, "error": {"code": "no_model", "message": "..."}}
```

Every request opens one connection. The `id` correlates the response.

### Methods

| Method | Params | Result |
|---|---|---|
| `rpc.capabilities` | `{}` | `{ protocol, methods }` |
| `llm.complete` | `{ systemPrompt?, messages, model? }` | `{ text, model }` |

`llm.complete` runs an isolated model call in the same pi process, with the same
model and credentials, but with **no tools** and no conversation history. The
caller provides the grounding (for example, a diff) in `messages`.

`messages` is an array of `{ "role": "user", "content": "..." }` (user messages
only in the MVP). `model` is an optional `{ "provider": "...", "id": "..." }`
override; by default the active model is used.

### Structured errors

Server errors are `{ code, message }`:

| code | meaning |
|---|---|
| `unsupported_method` | unknown method |
| `invalid_params` | bad params |
| `no_context` | no active pi context |
| `no_model` | no model selected |
| `provider_error` | model/provider failure |
| `timeout` | server-side safety cap reached |
| `aborted` | aborted |
| `internal` | unexpected error |

The Lua client normalizes local failures to the same shape:

| code | meaning |
|---|---|
| `no_session` | no pi session with the extension |
| `connect_failed` | could not connect to the socket |
| `client_timeout` | Neovim stopped waiting (does not cancel) |
| `invalid_response` | unparseable response |
| `connection_closed` | socket closed before responding |

### Timeout is not cancellation

A **client timeout** (`opts.timeout` in Lua, or closing the connection) means
Neovim stops waiting. It does **not** cancel the call: the server may keep
working and its result is discarded.

The server applies its own safety cap to `llm.complete` and aborts the model
call, returning `{ "code": "timeout" }` while the connection is still open. That
is server-side cancellation.

There is no explicit cancellation in the MVP.

### Raw clients

Any tool can talk to the socket directly:

```bash
echo '{"type":"prompt","message":"hello"}' | socat - UNIX-CONNECT:/tmp/pi-nvim-sockets/<hash>.sock
```

## Lua API

```lua
local pi = require("pi-nvim")

-- Generic RPC
pi.request(method, params, function(err, result)
  -- err is { code, message } or nil
end, { timeout = 60000 })

-- Sugar
pi.complete({ messages = { { role = "user", content = "..." } } }, function(err, result)
  print(result.text)
end)

pi.capabilities(function(err, caps)
  print(caps.protocol, table.concat(caps.methods, ", "))
end)
```

`request` targets the same session `:PiSessions` selects.

### Building a plugin on pi-nvim

A plugin adds business logic on top of `llm.complete`. For example, a "describe
this diff" capability:

```lua
require("pi-nvim").complete({
  systemPrompt = "Return only a one-line description of the change.",
  messages = { { role = "user", content = diff } },
}, function(err, result)
  if err then
    vim.notify(err.code .. ": " .. err.message, vim.log.levels.ERROR)
    return
  end
  print(result.text)
end)
```

pi-nvim stays infrastructure; the prompt and the business rules stay in the
plugin.

## Testing

`scripts/smoke.sh` starts a throwaway `pi --mode rpc` session with this repo's
extension and drives it from a headless Neovim using this repo's Lua module. It
does not touch your running sessions or your settings.

```bash
scripts/smoke.sh                 # protocol only (no tokens)
WITH_MODEL=1 scripts/smoke.sh    # also llm.complete (uses the active model)
```

The script derives the repo root from its own location; override it with
`FORK=/path/to/pi-nvim`. It exercises `rpc.capabilities`, an unknown method, and
invalid params (and `llm.complete` when `WITH_MODEL=1`).

It prints one `PASS`/`FAIL` line per check plus a final `RESULT: PASS|FAIL`, and
exits non-zero when anything fails.

## Health

```vim
:checkhealth pi-nvim
```

Checks libuv, the `pi` executable, the discovered sessions, the resolved
session, and the RPC server (`rpc.capabilities` / `llm.complete`).

## License

MIT
