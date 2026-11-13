local M = {}

--- pi's built-in slash commands.
---
--- Those are dispatched by pi's interactive TUI, not by the agent session, and
--- there is no public extension API to run them, so they only work when pi runs
--- in a terminal we can type into. Keep in sync with pi's interactive mode
--- (24 commands as of pi 0.86.1).
local BUILTIN_COMMANDS = {
  "settings",
  "model",
  "tree",
  "thinking",
  "scoped-models",
  "export",
  "import",
  "share",
  "bug",
  "copy",
  "name",
  "session",
  "changelog",
  "hotkeys",
  "fork",
  "clone",
  "trust",
  "login",
  "logout",
  "new",
  "compact",
  "resume",
  "reload",
  "quit",
}

local BUILTIN_SET = {}
for _, name in ipairs(BUILTIN_COMMANDS) do
  BUILTIN_SET[name] = true
end

--- How long to wait for a reply over the socket before giving up (ms).
local SEND_TIMEOUT_MS = 5000

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Use the raw `:cmd` argument as a prompt (nil when empty). `args.args`
--- keeps the text exactly as typed, unlike the split `fargs`.
local function text_from_args(args)
  if not args then return nil end
  local text = trim(args.args or "")
  if text == "" then return nil end
  return text
end

--- Directory holding the .info manifests / marker files. Must match the
--- pi extension's SOCKETS_DIR: /tmp on unix, %TEMP% on Windows.
local function sockets_dir()
  -- Overridable so tests (and users on a non-/tmp setup) can point both sides at
  -- the same directory; the pi extension reads the same variable.
  local override = vim.env.PI_NVIM_SOCKETS_DIR
  if override and override ~= "" then return override end

  if vim.fn.has("win32") == 1 then
    local tmp = vim.env.TEMP or vim.env.TMP
    return tmp and (tmp:gsub("\\", "/") .. "/pi-nvim-sockets") or nil
  end
  return "/tmp/pi-nvim-sockets"
end

--- Is a pid from a session manifest still running?
--- Unknown/unsupported cases count as alive so a session is never hidden by mistake.
--- @param pid number|nil
--- @return boolean
local function pid_alive(pid)
  if type(pid) ~= "number" then return true end
  local ok, res, err = pcall(vim.uv.kill, pid, 0)
  if not ok then return true end
  if res == 0 or res == true then return true end
  -- luv reports errors as "ESRCH: no such process", so match the prefix rather
  -- than the bare code; anything else (EPERM) means the process exists.
  return not tostring(err):match("^ESRCH")
end

--- @class pi_nvim.Session
--- @field socket string          Address to connect to
--- @field sock_file string       Manifest's sibling file (socket or liveness marker)
--- @field cwd string|nil         Directory pi was started in
--- @field pid number|nil
--- @field startedAt string|nil
--- @field mtime number           Manifest mtime, used to pick the newest session
--- @field is_current_cwd boolean

--- Read a session manifest.
--- @param info_path string
--- @return table|nil
local function read_manifest(info_path)
  local ok, content = pcall(vim.fn.readfile, info_path)
  if not ok or not content or not content[1] then return nil end
  local parsed_ok, info = pcall(vim.json.decode, content[1])
  if not parsed_ok or type(info) ~= "table" then return nil end
  return info
end

--- All live pi sessions found on disk, newest first is not guaranteed: callers
--- compare mtime. Dead sessions (stale manifests, exited pids) are filtered out.
--- @return pi_nvim.Session[]
function M.sessions()
  local sd = sockets_dir()
  if not sd then return {} end
  local ok, files = pcall(vim.fn.glob, sd .. "/*.info", false, true)
  if not ok or not files then return {} end

  local cwd = vim.uv.cwd()
  local sessions = {}
  for _, info_path in ipairs(files) do
    local info = read_manifest(info_path)
    if info then
      -- The manifest is `<base>.sock.info` (unix) or `<base>.sock.info` next to a
      -- marker file (Windows); either way the sibling is the manifest path minus
      -- the ".info" suffix. The connect address always comes from the manifest.
      local sock_file = info_path:sub(1, -6)
      local stat = vim.uv.fs_stat(sock_file)
      if stat and pid_alive(info.pid) then
        table.insert(sessions, {
          socket = info.socket or sock_file,
          sock_file = sock_file,
          cwd = info.cwd,
          pid = info.pid,
          startedAt = info.startedAt,
          mtime = stat.mtime.sec,
          is_current_cwd = info.cwd == cwd,
        })
      end
    end
  end
  return sessions
end

--- @class pi_nvim.Config
--- @field socket_path string|nil  Override socket path (default: auto-discover)
--- @field set_default_keymaps boolean|nil  Whether to create the default <leader>p mappings (default: true)
--- @field autoreload boolean|nil  Force `autoread` and poll changed files while a pi session is reachable (default: false)
--- @field notify boolean|nil  Notify when pi settles a task or the session stops (default: true)
M.config = {
  socket_path = nil,
  set_default_keymaps = true,
  autoreload = false,
  notify = true,
}

--- Socket picked with :PiSessions. Kept out of M.config so it never looks like a
--- user override and can be dropped as soon as the session goes away.
--- @type string|nil
M._pinned_socket = nil

--- @type uv_timer_t|nil
M._reload_timer = nil

--- Forget a socket pinned with :PiSessions.
function M.unpin()
  M._pinned_socket = nil
end

--- Delay before retrying the notification connection (ms).
local WATCH_RETRY_MS = 1000

local watch_connect

--- @type uv_pipe_t|nil
M._watch_pipe = nil
--- @type uv_timer_t|nil
M._watch_timer = nil
--- @type string
M._watch_buf = ""

--- Dispatch one event line pushed by pi. Runs on the main loop.
--- @param line string
local function handle_event(line)
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" then return end
  if msg.type == "agent_settled" then
    vim.notify("pi: task finished", vim.log.levels.INFO)
  elseif msg.type == "session_shutdown" then
    vim.notify("pi: session stopped (" .. tostring(msg.reason or "unknown") .. ")", vim.log.levels.WARN)
  end
end

--- Stop the notification watcher (safe to call when it was never started).
local function watch_stop()
  if M._watch_timer then
    local timer = M._watch_timer
    M._watch_timer = nil
    pcall(function()
      timer:stop()
      timer:close()
    end)
  end
  if M._watch_pipe then
    local pipe = M._watch_pipe
    M._watch_pipe = nil
    M._watch_buf = ""
    pcall(function()
      pipe:read_stop()
      pipe:close()
    end)
  end
end

--- Retry the connection once, a second from now.
local function watch_retry()
  if M._watch_timer or not M.config.notify then return end
  local timer = vim.uv.new_timer()
  if not timer then return end
  M._watch_timer = timer
  timer:start(WATCH_RETRY_MS, 0, vim.schedule_wrap(function()
    if M._watch_timer == timer then
      M._watch_timer = nil
      pcall(function()
        timer:stop()
        timer:close()
      end)
    end
    watch_connect()
  end))
end

--- Keep one connection open so pi can push events; retry while pi is down.
watch_connect = function()
  if not M.config.notify or M._watch_pipe then return end

  local sock_path = M.get_socket_path()
  if not sock_path then
    watch_retry()
    return
  end

  local pipe = vim.uv.new_pipe(false)
  if not pipe then
    watch_retry()
    return
  end
  M._watch_pipe = pipe
  M._watch_buf = ""

  local function teardown()
    if M._watch_pipe ~= pipe then return end
    M._watch_pipe = nil
    M._watch_buf = ""
    pcall(function()
      pipe:read_stop()
      pipe:close()
    end)
  end

  pipe:connect(sock_path, function(err)
    if err then
      teardown()
      watch_retry()
      return
    end

    local wrote = pcall(pipe.write, pipe, '{"type":"subscribe"}\n')
    if not wrote then
      teardown()
      watch_retry()
      return
    end
    pipe:read_start(function(read_err, data)
      if read_err or not data then
        teardown()
        watch_retry()
        return
      end

      M._watch_buf = M._watch_buf .. data
      while true do
        local nl = M._watch_buf:find("\n", 1, true)
        if not nl then break end
        local line = M._watch_buf:sub(1, nl - 1)
        M._watch_buf = M._watch_buf:sub(nl + 1)
        if line ~= "" then
          vim.schedule(function() handle_event(line) end)
        end
      end
    end)
  end)
end

--- Stop the background pollers (autoreload and notifications).
--- Safe to call when neither was started.
function M.stop()
  if M._reload_timer then
    local timer = M._reload_timer
    M._reload_timer = nil
    pcall(function()
      timer:stop()
      timer:close()
    end)
  end
  watch_stop()
end

--- @param opts pi_nvim.Config|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  M.unpin()

  -- Calling setup() twice (lazy loaders, :packadd, config reloads) must not
  -- create duplicate commands or leave a second timer running.
  if vim.g.pi_nvim_setup then return end
  vim.g.pi_nvim_setup = true

  -- Opt-in auto-reload of buffers changed externally (e.g. by the pi agent).
  -- Off by default: it forces `autoread` on every buffer and polls once a second.
  if M.config.autoreload then
    vim.o.autoread = true
    M.stop()
    local timer = vim.uv.new_timer()
    M._reload_timer = timer
    timer:start(0, 1000, vim.schedule_wrap(function()
      if M.get_socket_path() then
        pcall(vim.cmd, "silent! checktime")
      end
    end))
  end

  -- Push notifications: keep a connection open so pi can report task finishes
  -- and session shutdowns without Neovim asking.
  if M.config.notify then
    watch_connect()
    local group = vim.api.nvim_create_augroup("pi_nvim_notify", { clear = true })
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = group,
      callback = function() watch_stop() end,
      desc = "Release the pi-nvim notification connection",
    })
  end

  -- Commands
  vim.api.nvim_create_user_command("PiSend", function(args)
    -- `:PiSend /skill:foo` sends the text straight away; no args opens the
    -- prompt. Without nargs, any argument would raise E488.
    M.prompt(text_from_args(args))
  end, { force = true, nargs = "*", desc = "Send a prompt to pi" })

  vim.api.nvim_create_user_command("PiSendFile", function()
    M.send_file()
  end, { force = true, desc = "Send current file to pi with a prompt" })

  vim.api.nvim_create_user_command("PiSendSelection", function()
    M.send_selection()
  end, { force = true, range = true, desc = "Send visual selection to pi with a prompt" })

  vim.api.nvim_create_user_command("PiSendBuffer", function()
    M.send_buffer()
  end, { force = true, desc = "Send entire buffer to pi with a prompt" })

  vim.api.nvim_create_user_command("Pi", function(args)
    -- `:Pi /settings` (or any text) sends it directly, so a slash command
    -- typed on the command line is routed instead of raising E488.
    local text = text_from_args(args)
    if text then
      M.prompt(text)
      return
    end

    local ui = require("pi-nvim.ui")
    local selection = nil
    if args.range == 2 then
      selection = ui.capture_selection()
    end
    ui.open({ selection = selection })
  end, { force = true, nargs = "*", range = true, desc = "Open pi send dialog, or send the given text" })

  vim.api.nvim_create_user_command("PiPing", function()
    M.ping()
  end, { force = true, desc = "Ping the pi session" })

  vim.api.nvim_create_user_command("PiSessions", function()
    M.list_sessions()
  end, { force = true, desc = "List running pi sessions" })

  if M.config.set_default_keymaps then
    -- Default keymap: <leader>p in normal and visual mode
    vim.keymap.set("n", "<leader>p", ":Pi<CR>", { silent = true, desc = "Send to pi" })
    vim.keymap.set("v", "<leader>p", ":Pi<CR>", { silent = true, desc = "Send selection to pi" })
  end
end

--- Resolve the socket path to use.
--- Priority: config override > pinned session (:PiSessions) > newest session started in this cwd.
--- @return string|nil
function M.get_socket_path()
  if M.config.socket_path then
    return M.config.socket_path
  end

  local sessions = M.sessions()

  if M._pinned_socket then
    for _, s in ipairs(sessions) do
      if s.socket == M._pinned_socket then return s.socket end
    end
    -- The pinned session is gone: fall through to auto-discovery.
    M._pinned_socket = nil
  end

  -- Never fall back to another project's session: a prompt for this cwd must
  -- not land in an unrelated agent's conversation.
  local best, best_mtime = nil, -1
  for _, s in ipairs(sessions) do
    if s.is_current_cwd and s.mtime > best_mtime then
      best, best_mtime = s, s.mtime
    end
  end

  return best and best.socket or nil
end

--- Send a raw JSON message to the pi socket and call cb with the parsed response.
--- @param msg table
--- @param cb fun(err: string|nil, response: table|nil)|nil
function M.send_raw(msg, cb)
  local sock_path = M.get_socket_path()
  if not sock_path then
    local err
    if #M.sessions() > 0 then
      err = "No pi session running in this directory. Use :PiSessions to see the other sessions."
    else
      err = "No pi session found. Is pi running with the pi-nvim extension?"
    end
    vim.notify(err, vim.log.levels.ERROR)
    if cb then cb(err, nil) end
    return
  end

  local client = vim.uv.new_pipe(false)
  if not client then
    local err = "Failed to create pipe"
    vim.notify(err, vim.log.levels.ERROR)
    if cb then cb(err, nil) end
    return
  end

  local timer = vim.uv.new_timer()
  local done = false

  local function close()
    if not client:is_closing() then
      pcall(client.read_stop, client)
      client:close()
    end
    if timer then
      local t = timer
      timer = nil
      pcall(function()
        t:stop()
        t:close()
      end)
    end
  end

  local function finish(err, response)
    if done then return end
    done = true
    close()
    vim.schedule(function()
      if cb then cb(err, response) end
    end)
  end

  -- A pi session that never answers would otherwise leak the pipe and leave the
  -- caller waiting forever.
  if timer then
    timer:start(SEND_TIMEOUT_MS, 0, vim.schedule_wrap(function()
      finish("timeout", nil)
    end))
  end

  client:connect(sock_path, function(err)
    if err then
      vim.schedule(function()
        vim.notify("Failed to connect to pi: " .. err, vim.log.levels.ERROR)
      end)
      finish(err, nil)
      return
    end

    local payload = vim.json.encode(msg) .. "\n"
    client:write(payload)

    local buf = ""
    client:read_start(function(read_err, data)
      if read_err then
        finish(read_err, nil)
        return
      end
      if not data then
        -- EOF without a complete line
        finish("pi closed the connection before replying", nil)
        return
      end
      buf = buf .. data
      local nl = buf:find("\n", 1, true)
      if not nl then return end
      local line = buf:sub(1, nl - 1)
      local ok, resp = pcall(vim.json.decode, line)
      if ok and resp then
        finish(nil, resp)
      else
        finish("Invalid response from pi", nil)
      end
    end)
  end)
end

--- Classify something the user typed into the :Pi dialog.
---
--- - "builtin": a pi built-in command (/settings, /model, …) or user bash (!ls).
---   Those are TUI-only, so they need a pi terminal.
--- - "expandable": any other slash input (/skill:name, /template, extension
---   commands), which pi can expand or dispatch itself.
--- - "prompt": ordinary text for the model.
---
--- @param text string|nil
--- @return "builtin"|"expandable"|"prompt"
function M.classify_input(text)
  if type(text) ~= "string" then return "prompt" end
  local trimmed = trim(text)
  if trimmed == "" then return "prompt" end

  -- pi's user-bash mode: "!cmd" runs a shell command, "!!cmd" keeps it in context.
  if trimmed:sub(1, 1) == "!" then return "builtin" end
  if trimmed:sub(1, 1) ~= "/" then return "prompt" end

  local token = trimmed:match("^(%S+)")
  -- "/etc/hosts" is a path, not a command: a command name has no further slash.
  if token:find("/", 2, true) then return "prompt" end

  local name = token:sub(2):match("^([%w%-_]+)")
  if not name then return "prompt" end
  if BUILTIN_SET[name] then return "builtin" end
  return "expandable"
end

--- Find a loaded terminal buffer that is running pi.
--- @return integer|nil
local function find_pi_terminal()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_valid(buf)
      and vim.api.nvim_buf_is_loaded(buf)
      and vim.bo[buf].buftype == "terminal"
    then
      local name = vim.api.nvim_buf_get_name(buf):lower()
      -- Match ":pi" or ":pi " at the end/middle of the term name
      if name:match(":pi$") or name:match(":pi%s") then
        return buf
      end
    end
  end
  return nil
end

--- Type into a pi terminal buffer, showing its window first.
--- @param term_buf integer
--- @param message string
local function send_to_terminal(term_buf, message)
  local id = vim.b[term_buf].terminal_job_id
  if not id then return false end

  -- Focus or open the terminal window
  local win = vim.fn.bufwinid(term_buf)
  if win ~= -1 then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, term_buf)
  end

  -- Send via bracketed paste to handle newlines correctly, and append \r to submit
  local payload = "\x1b[200~" .. message .. "\x1b[201~\r"
  vim.api.nvim_chan_send(id, payload)
  vim.cmd("startinsert")
  return true
end

--- Send a prompt over the socket.
--- @param message string
--- @param expand_prompt_templates boolean  Let pi dispatch extension commands and expand /skill: + /template
local function send_prompt_socket(message, expand_prompt_templates)
  local msg = { type = "prompt", message = message }
  if expand_prompt_templates then
    msg.expandPromptTemplates = true
  end

  M.send_raw(msg, function(err, resp)
    if err == "timeout" then
      vim.notify(string.format("pi did not reply within %d ms", SEND_TIMEOUT_MS), vim.log.levels.ERROR)
      return
    end
    if err then return end
    if resp and not resp.ok then
      vim.notify("pi error: " .. (resp.error or "unknown"), vim.log.levels.ERROR)
    end
  end)
end

---Report the outcome of a dispatch to the user.
---@param kind string classify_input() result
---@param context_dropped boolean|nil attached context was left out
local function notify_sent(kind, context_dropped)
  local text = (kind == "prompt") and "Pi: Prompt sent" or "Pi: Command executed"
  if kind ~= "prompt" and context_dropped then
    text = text .. " (context not sent)"
  end
  vim.notify(text, vim.log.levels.INFO)
end

--- Send a prompt string to pi.
--- @param message string|nil  If nil, prompts the user for input
--- @param opts table|nil  context_dropped: attached context was not sent
function M.prompt(message, opts)
  if not message then
    vim.ui.input({ prompt = "Pi prompt: " }, function(input)
      if input and input ~= "" then
        M.prompt(input)
      end
    end)
    return
  end

  local kind = M.classify_input(message)
  local term_buf = find_pi_terminal()

  if term_buf and send_to_terminal(term_buf, message) then
    notify_sent(kind, opts and opts.context_dropped)
    return
  end

  if kind == "builtin" then
    -- Built-in commands exist only in pi's TUI. Sending them over the socket
    -- would turn them into literal text for the model, so refuse loudly.
    vim.notify(
      string.format(
        "'%s' is a pi built-in command and only works while pi runs in a terminal. Open it with <leader>a (or :TermVertical) and try again.",
        trim(message):match("^(%S+)")
      ),
      vim.log.levels.WARN
    )
    return
  end

  send_prompt_socket(message, kind == "expandable")
  notify_sent(kind, opts and opts.context_dropped)
end

--- Send the current file path with optional prompt.
function M.send_file()
  local file = vim.fn.expand("%:p")
  if file == "" then
    vim.notify("No file open", vim.log.levels.WARN)
    return
  end

  vim.ui.input({ prompt = "Pi prompt (file: " .. vim.fn.expand("%:.") .. "): " }, function(input)
    if not input then return end

    local message
    if input == "" then
      message = string.format("Look at this file: %s", file)
    else
      message = string.format("File: %s\n\n%s", file, input)
    end
    M.prompt(message)
  end)
end

--- Send the visual selection with a prompt.
function M.send_selection()
  -- Get the visual selection
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local lines = vim.fn.getregion(start_pos, end_pos, { type = vim.fn.visualmode() })
  local selection = table.concat(lines, "\n")

  if selection == "" then
    vim.notify("Empty selection", vim.log.levels.WARN)
    return
  end

  local file = vim.fn.expand("%:.")
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  local ft = vim.bo.filetype

  vim.ui.input({ prompt = "Pi prompt (selection): " }, function(input)
    if not input then return end

    local header = string.format("%s lines %d-%d", file, start_line, end_line)
    local message
    if input == "" then
      message = string.format("Look at this code from %s:\n\n```%s\n%s\n```", header, ft, selection)
    else
      message = string.format("%s\n\nFrom %s:\n```%s\n%s\n```", input, header, ft, selection)
    end
    M.prompt(message)
  end)
end

--- Send the entire buffer contents with a prompt.
function M.send_buffer()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local content = table.concat(lines, "\n")
  local file = vim.fn.expand("%:.")
  local ft = vim.bo.filetype

  vim.ui.input({ prompt = "Pi prompt (buffer): " }, function(input)
    if not input then return end

    local message
    if input == "" then
      message = string.format("Look at this file %s:\n\n```%s\n%s\n```", file, ft, content)
    else
      message = string.format("%s\n\nFile: %s\n```%s\n%s\n```", input, file, ft, content)
    end
    M.prompt(message)
  end)
end

--- Ping the pi session to check connectivity.
function M.ping()
  M.send_raw({ type = "ping" }, function(err, resp)
    if err then
      vim.notify("Pi not reachable: " .. err, vim.log.levels.ERROR)
    elseif resp and resp.type == "pong" then
      vim.notify("Pi is alive! ✓", vim.log.levels.INFO)
    else
      vim.notify("Unexpected response from pi", vim.log.levels.WARN)
    end
  end)
end

--- Format a manifest's ISO timestamp as HH:MM.
--- @param started_at string|nil
--- @return string
local function format_started(started_at)
  if not started_at then return "" end
  local h, mi = started_at:match("T(%d+):(%d+)")
  if h and mi then
    return string.format("%s:%s", h, mi)
  end
  return started_at
end

--- List all running pi sessions.
function M.list_sessions()
  local sessions = M.sessions()
  if #sessions == 0 then
    vim.notify("No pi sessions found", vim.log.levels.INFO)
    return
  end

  local items = {}
  local current = M.get_socket_path()
  for _, s in ipairs(sessions) do
    local marker = (current == s.socket) and "●" or "○"
    local started = format_started(s.startedAt)
    local time_str = started ~= "" and string.format(" started %s", started) or ""
    table.insert(items, string.format("%s %s [pid %s%s]", marker, s.cwd or "?", s.pid or "?", time_str))
  end

  vim.ui.select(items, { prompt = "Pi sessions:" }, function(choice, idx)
    if not choice or not idx then return end
    local session = sessions[idx]
    if session then
      M._pinned_socket = session.socket
      vim.notify(
        string.format("Connected to pi at %s [pid %s]", session.cwd or "?", session.pid or "?"),
        vim.log.levels.INFO
      )
    end
  end)
end

return M
