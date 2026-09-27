local M = {}

--- Directory holding the .info manifests / marker files. Must match the
--- pi extension's SOCKETS_DIR: /tmp on unix, %TEMP% on Windows.
local function sockets_dir()
  if vim.fn.has("win32") == 1 then
    local tmp = vim.env.TEMP or vim.env.TMP
    return tmp and (tmp:gsub("\\", "/") .. "/pi-nvim-sockets") or nil
  end
  return "/tmp/pi-nvim-sockets"
end

--- @class pi_nvim.Config
--- @field socket_path string|nil  Override socket path (default: auto-discover)
--- @field set_default_keymaps boolean|nil  Whether to create the default <leader>p mappings (default: true)
M.config = {
  socket_path = nil,
  set_default_keymaps = true,
}

--- @param opts pi_nvim.Config|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- Auto-reload buffers when files are changed externally (e.g. by pi agent).
  -- Only polls when a pi session is reachable. Respects existing autoread setting.
  if not vim.o.autoread then
    vim.o.autoread = true
  end
  local reload_timer = vim.uv.new_timer()
  reload_timer:start(0, 1000, vim.schedule_wrap(function()
    if M.get_socket_path() then
      pcall(vim.cmd, "silent! checktime")
    end
  end))

  -- Commands
  vim.api.nvim_create_user_command("PiSend", function()
    M.prompt()
  end, { desc = "Send a prompt to pi" })

  vim.api.nvim_create_user_command("PiSendFile", function()
    M.send_file()
  end, { desc = "Send current file to pi with a prompt" })

  vim.api.nvim_create_user_command("PiSendSelection", function()
    M.send_selection()
  end, { range = true, desc = "Send visual selection to pi with a prompt" })

  vim.api.nvim_create_user_command("PiSendBuffer", function()
    M.send_buffer()
  end, { desc = "Send entire buffer to pi with a prompt" })

  vim.api.nvim_create_user_command("Pi", function(args)
    local ui = require("pi-nvim.ui")
    local selection = nil
    if args.range == 2 then
      selection = ui.capture_selection()
    end
    ui.open({ selection = selection })
  end, { range = true, desc = "Open pi send dialog" })

  if M.config.set_default_keymaps then
    -- Default keymap: <leader>p in normal and visual mode
    vim.keymap.set("n", "<leader>p", ":Pi<CR>", { silent = true, desc = "Send to pi" })
    vim.keymap.set("v", "<leader>p", ":Pi<CR>", { silent = true, desc = "Send selection to pi" })
  end

  vim.api.nvim_create_user_command("PiPing", function()
    M.ping()
  end, { desc = "Ping the pi session" })

  vim.api.nvim_create_user_command("PiSessions", function()
    M.list_sessions()
  end, { desc = "List running pi sessions" })
end

--- Parse the pid out of a "<hash>-<pid>.sock" filename.
--- @param sock_path string
--- @return string|nil
local function pid_from_sock(sock_path)
  local base = sock_path:match("([^/]+)%.sock$")
  if not base then return nil end
  return base:match("%-(%d+)$")
end

--- Read and decode the optional sidecar manifest for a socket.
--- @param sock_path string
--- @return table|nil
local function read_manifest(sock_path)
  local ok, content = pcall(vim.fn.readfile, sock_path .. ".info")
  if ok and content and content[1] then
    local parsed_ok, info = pcall(vim.json.decode, content[1])
    if parsed_ok and type(info) == "table" then
      return info
    end
  end
  return nil
end

--- Best-effort cwd lookup for a pid (Linux only; nil elsewhere).
--- @param pid string|nil
--- @return string|nil
local function cwd_for_pid(pid)
  if not pid then return nil end
  local ok, resolved = pcall(vim.uv.fs_readlink, "/proc/" .. pid .. "/cwd")
  if ok and resolved then return resolved end
  return nil
end

--- Whether a pid is definitely dead. Returns nil when it can't be told.
--- @param pid string|nil
--- @return boolean|nil
local function pid_dead(pid)
  if not pid or vim.fn.has("linux") ~= 1 then return nil end
  return vim.uv.fs_stat("/proc/" .. pid) == nil
end

--- Discover every live pi session by scanning the sockets directory.
---
--- The socket file is the source of truth: on unix it is the listening socket,
--- on Windows a liveness marker. The .info manifest is only used to enrich
--- metadata, so sessions stay visible even if the manifest is missing.
--- @return table[] list of { socket, cwd, pid, started, mtime }
function M.discover_sessions()
  local sd = sockets_dir()
  if not sd then return {} end

  local sessions = {}
  local seen = {}

  local function add(sock_file)
    if seen[sock_file] then return end
    local stat = vim.uv.fs_stat(sock_file)
    if not stat then return end
    seen[sock_file] = true

    local info = read_manifest(sock_file)
    local pid = (info and info.pid) or pid_from_sock(sock_file)
    if pid_dead(pid) then return end

    -- The connect address comes from the manifest when present (needed for
    -- Windows named pipes), otherwise derive it from the socket filename.
    local addr = info and info.socket
    if not addr then
      local base = sock_file:match("([^/]+)%.sock$")
      if base and vim.fn.has("win32") == 1 then
        addr = "\\\\.\\pipe\\pi-nvim-" .. base
      else
        addr = sock_file
      end
    end

    table.insert(sessions, {
      socket = addr,
      cwd = (info and info.cwd) or cwd_for_pid(pid) or "?",
      pid = pid or "?",
      started = info and info.startedAt or nil,
      mtime = stat.mtime.sec,
    })
  end

  -- Manifests first (they may carry the Windows pipe address), then any
  -- socket that has no manifest at all.
  local ok, infos = pcall(vim.fn.glob, sd .. "/*.info", false, true)
  if ok and infos then
    for _, info_path in ipairs(infos) do
      add(info_path:sub(1, -6)) -- strip ".info"
    end
  end
  local ok2, socks = pcall(vim.fn.glob, sd .. "/*.sock", false, true)
  if ok2 and socks then
    for _, sock_path in ipairs(socks) do
      add(sock_path)
    end
  end

  return sessions
end

--- Resolve the socket path to use.
--- Priority: config override > cwd-based > latest symlink
--- @return string|nil
function M.get_socket_path()
  if M.config.socket_path then
    return M.config.socket_path
  end

  local sessions = M.discover_sessions()
  local cwd = vim.uv.cwd()
  local best_sock, best_mtime
  local any_sock, any_mtime
  for _, s in ipairs(sessions) do
    if s.cwd == cwd and (not best_mtime or s.mtime > best_mtime) then
      best_sock, best_mtime = s.socket, s.mtime
    end
    if not any_mtime or s.mtime > any_mtime then
      any_sock, any_mtime = s.socket, s.mtime
    end
  end
  if best_sock then return best_sock end
  if any_sock then return any_sock end

  -- Fall back to latest symlink (unix only; Windows has none)
  if vim.fn.has("win32") == 0 then
    local latest = "/tmp/pi-nvim-latest.sock"
    if vim.uv.fs_stat(latest) then
      return latest
    end
  end

  return nil
end

--- Send a raw JSON message to the pi socket and call cb with the parsed response.
--- @param msg table
--- @param cb fun(err: string|nil, response: table|nil)|nil
function M.send_raw(msg, cb)
  local sock_path = M.get_socket_path()
  if not sock_path then
    local err = "No pi session found. Is pi running with pi-nvim extension?"
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

  client:connect(sock_path, function(err)
    if err then
      vim.schedule(function()
        vim.notify("Failed to connect to pi: " .. err, vim.log.levels.ERROR)
        if cb then cb(err, nil) end
      end)
      return
    end

    local payload = vim.json.encode(msg) .. "\n"
    client:write(payload)

    local buf = ""
    client:read_start(function(read_err, data)
      if read_err then
        client:close()
        vim.schedule(function()
          if cb then cb(read_err, nil) end
        end)
        return
      end
      if data then
        buf = buf .. data
        local nl = buf:find("\n")
        if nl then
          local line = buf:sub(1, nl - 1)
          client:read_stop()
          client:close()
          vim.schedule(function()
            local ok, resp = pcall(vim.json.decode, line)
            if ok and resp then
              if cb then cb(nil, resp) end
            else
              if cb then cb("Invalid response from pi", nil) end
            end
          end)
        end
      else
        -- EOF
        client:close()
      end
    end)
  end)
end

-- ============================================================================
-- RPC (namespaced request/response)
-- ============================================================================

local request_counter = 0

--- @class pi_nvim.RpcError
--- @field code string
--- @field message string

--- Perform a namespaced RPC request and call cb with (err, result).
---
--- `err` is a structured { code, message } table (nil on success).
---
--- A client timeout is NOT cancellation: when it fires, Neovim stops waiting
--- and closes the connection, but the server may keep working. The result is
--- discarded.
---
--- @param method string
--- @param params table|nil
--- @param cb fun(err: pi_nvim.RpcError|nil, result: any)
--- @param opts { timeout?: integer }|nil  timeout in ms (default 120000)
function M.request(method, params, cb, opts)
  opts = opts or {}
  local timeout = opts.timeout or 120000

  local sock_path = M.get_socket_path()
  if not sock_path then
    cb({ code = "no_session", message = "No pi session found. Is pi running with pi-nvim extension?" })
    return
  end

  request_counter = request_counter + 1
  local id = string.format("%d-%d", vim.fn.getpid(), request_counter)

  local client = vim.uv.new_pipe(false)
  if not client then
    cb({ code = "internal", message = "Failed to create pipe" })
    return
  end

  local finished = false
  local timer = vim.uv.new_timer()

  local function finish(err, result)
    if finished then return end
    finished = true
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    pcall(function() client:close() end)
    vim.schedule(function() cb(err, result) end)
  end

  local buf = ""

  client:connect(sock_path, function(err)
    if err then
      finish({ code = "connect_failed", message = "Failed to connect to pi: " .. tostring(err) })
      return
    end

    client:read_start(function(read_err, data)
      if read_err then
        finish({ code = "connection_closed", message = "pi socket read error: " .. tostring(read_err) })
        return
      end
      if not data then
        finish({ code = "connection_closed", message = "pi closed the connection before responding" })
        return
      end

      buf = buf .. data
      local nl = buf:find("\n")
      if not nl then return end

      local line = buf:sub(1, nl - 1)
      client:read_stop()

      local ok, resp = pcall(vim.json.decode, line)
      if not ok or type(resp) ~= "table" then
        finish({ code = "invalid_response", message = "Invalid response from pi" })
      elseif resp.ok then
        finish(nil, resp.result)
      elseif type(resp.error) == "table" then
        finish({ code = resp.error.code or "internal", message = resp.error.message or "unknown error" })
      else
        finish({ code = "internal", message = tostring(resp.error or "unknown error") })
      end
    end)

    local payload = vim.json.encode({ id = id, type = "request", method = method, params = params or {} }) .. "\n"
    client:write(payload)
  end)

  timer:start(timeout, 0, function()
    finish({ code = "client_timeout", message = "Timed out waiting for pi (the request is not cancelled)" })
  end)
end

--- Convenience wrapper for the "llm.complete" method.
--- @param params { systemPrompt?: string, messages: table[], model?: { provider: string, id: string } }
--- @param cb fun(err: pi_nvim.RpcError|nil, result: any)
--- @param opts { timeout?: integer }|nil
function M.complete(params, cb, opts)
  M.request("llm.complete", params, cb, opts)
end

--- Convenience wrapper for the "rpc.capabilities" method.
--- @param cb fun(err: pi_nvim.RpcError|nil, result: any)
--- @param opts { timeout?: integer }|nil
function M.capabilities(cb, opts)
  M.request("rpc.capabilities", {}, cb, opts)
end

--- Send a prompt string to pi.
--- @param message string|nil  If nil, prompts the user for input
function M.prompt(message)
  if message then
    -- Check for a running pi terminal buffer
    local term_buf = nil
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "terminal" then
        local name = vim.api.nvim_buf_get_name(buf)
        -- Match ":pi" or ":pi " at the end/middle of the term name
        if name:lower():match(":pi$") or name:lower():match(":pi%s") then
          term_buf = buf
          break
        end
      end
    end

    if term_buf then
      local id = vim.b[term_buf].terminal_job_id
      if id then
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
        
        vim.notify("Sent to pi terminal buffer", vim.log.levels.INFO)
        return
      end
    end

    M.send_raw({ type = "prompt", message = message }, function(err, resp)
      if err then return end
      if resp and resp.ok then
        vim.notify("Sent to pi", vim.log.levels.INFO)
      else
        vim.notify("pi error: " .. (resp and resp.error or "unknown"), vim.log.levels.ERROR)
      end
    end)
  else
    vim.ui.input({ prompt = "Pi prompt: " }, function(input)
      if input and input ~= "" then
        M.prompt(input)
      end
    end)
  end
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

--- List all running pi sessions.
function M.list_sessions()
  local sessions = M.discover_sessions()
  if #sessions == 0 then
    vim.notify("No pi sessions found", vim.log.levels.INFO)
    return
  end

  --- Format an ISO 8601 "...T14:10:09..." timestamp as " started 14:10".
  local function short_time(iso)
    if not iso then return "" end
    local h, mi = iso:match("T(%d+):(%d+)")
    if h and mi then return string.format(" started %s:%s", h, mi) end
    return ""
  end

  local items = {}
  local current = M.get_socket_path()
  for _, s in ipairs(sessions) do
    local marker = (current == s.socket) and "●" or "○"
    table.insert(items, string.format("%s %s [pid %s%s]", marker, s.cwd, s.pid, short_time(s.started)))
  end

  vim.ui.select(items, { prompt = "Pi sessions:" }, function(choice, idx)
    if not choice or not idx then return end
    local session = sessions[idx]
    if session then
      M.config.socket_path = session.socket
      vim.notify(string.format("Connected to pi at %s [pid %s]", session.cwd, session.pid), vim.log.levels.INFO)
    end
  end)
end

return M
