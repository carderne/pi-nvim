local M = {}

--- @class pi_nvim.Config
--- @field socket_path string|nil  Override socket path (default: auto-discover)
M.config = {
  socket_path = nil,
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

  -- Default keymap: <leader>p in normal and visual mode
  vim.keymap.set("n", "<leader>p", ":Pi<CR>", { silent = true, desc = "Send to pi" })
  vim.keymap.set("v", "<leader>p", ":Pi<CR>", { silent = true, desc = "Send selection to pi" })

  vim.api.nvim_create_user_command("PiPing", function()
    M.ping()
  end, { desc = "Ping the pi session" })

  vim.api.nvim_create_user_command("PiSessions", function()
    M.list_sessions()
  end, { desc = "List running pi sessions" })
end

--- Resolve the socket path to use.
--- Priority: config override > cwd-based > latest symlink
--- @return string|nil
function M.get_socket_path()
  if M.config.socket_path then
    return M.config.socket_path
  end

  local sockets_dir = "/tmp/pi-nvim-sockets"
  local cwd = vim.uv.cwd()

  -- Scan the sockets directory for .info files
  local ok, files = pcall(vim.fn.glob, sockets_dir .. "/*.info", false, true)
  if ok and files then
    -- First pass: exact cwd match, prefer newest socket
    local best_sock = nil
    local best_mtime = 0
    for _, info_path in ipairs(files) do
      local content_ok, content = pcall(vim.fn.readfile, info_path)
      if content_ok and content and content[1] then
        local parsed_ok, info = pcall(vim.json.decode, content[1])
        if parsed_ok and info then
          local sock = info_path:sub(1, -6) -- strip ".info"
          local stat = vim.uv.fs_stat(sock)
          if info.cwd == cwd and stat then
            if stat.mtime.sec > best_mtime then
              best_mtime = stat.mtime.sec
              best_sock = sock
            end
          end
        end
      end
    end
    if best_sock then return best_sock end

    -- Second pass: any live session (newest)
    for _, info_path in ipairs(files) do
      local sock = info_path:sub(1, -6)
      local stat = vim.uv.fs_stat(sock)
      if stat then
        if stat.mtime.sec > best_mtime then
          best_mtime = stat.mtime.sec
          best_sock = sock
        end
      end
    end
    if best_sock then return best_sock end
  end

  -- Fall back to latest symlink
  local latest = "/tmp/pi-nvim-latest.sock"
  if vim.uv.fs_stat(latest) then
    return latest
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
  local sockets_dir = "/tmp/pi-nvim-sockets"
  local ok, files = pcall(vim.fn.glob, sockets_dir .. "/*.info", false, true)
  if not ok or not files or #files == 0 then
    vim.notify("No pi sessions found", vim.log.levels.INFO)
    return
  end

  local sessions = {}
  for _, info_path in ipairs(files) do
    local content_ok, content = pcall(vim.fn.readfile, info_path)
    if content_ok and content and content[1] then
      local parsed_ok, info = pcall(vim.json.decode, content[1])
      if parsed_ok and info then
        local sock = info_path:sub(1, -6)
        local alive = vim.uv.fs_stat(sock) ~= nil
        if alive then
          -- Format start time as relative or short time
          local started = ""
          if info.startedAt then
            local ok2, ts = pcall(function()
              -- Parse ISO 8601: "2026-03-01T14:10:09.123Z"
              local y, mo, d, h, mi, s = info.startedAt:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
              if h and mi then
                return string.format("%s:%s", h, mi)
              end
              return info.startedAt
            end)
            if ok2 then started = ts end
          end
          table.insert(sessions, {
            cwd = info.cwd or "?",
            pid = info.pid or "?",
            started = started,
            socket = sock,
          })
        end
      end
    end
  end

  if #sessions == 0 then
    vim.notify("No pi sessions found", vim.log.levels.INFO)
    return
  end

  local items = {}
  local current = M.get_socket_path()
  for _, s in ipairs(sessions) do
    local marker = (current == s.socket) and "●" or "○"
    local time_str = s.started ~= "" and string.format(" started %s", s.started) or ""
    table.insert(items, string.format("%s %s [pid %s%s]", marker, s.cwd, s.pid, time_str))
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
