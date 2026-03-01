local M = {}

--- @class pi_nvim.Config
--- @field socket_path string|nil  Override socket path (default: auto-discover)
M.config = {
  socket_path = nil,
}

--- @param opts pi_nvim.Config|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

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

  vim.api.nvim_create_user_command("PiPing", function()
    M.ping()
  end, { desc = "Ping the pi nvim-bridge" })

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
    -- First pass: exact cwd match
    for _, info_path in ipairs(files) do
      local content_ok, content = pcall(vim.fn.readfile, info_path)
      if content_ok and content and content[1] then
        local parsed_ok, info = pcall(vim.json.decode, content[1])
        if parsed_ok and info then
          local sock = info_path:sub(1, -6) -- strip ".info"
          if info.cwd == cwd and vim.uv.fs_stat(sock) then
            return sock
          end
        end
      end
    end

    -- Second pass: any live session
    for _, info_path in ipairs(files) do
      local sock = info_path:sub(1, -6)
      if vim.uv.fs_stat(sock) then
        return sock
      end
    end
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
    local err = "No pi session found. Is pi running with nvim-bridge extension?"
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
        table.insert(sessions, {
          cwd = info.cwd or "?",
          socket = sock,
          alive = vim.uv.fs_stat(sock) ~= nil,
        })
      end
    end
  end

  if #sessions == 0 then
    vim.notify("No pi sessions found", vim.log.levels.INFO)
    return
  end

  local items = {}
  for _, s in ipairs(sessions) do
    local status = s.alive and "●" or "○"
    table.insert(items, string.format("%s %s", status, s.cwd))
  end

  vim.ui.select(items, { prompt = "Pi sessions:" }, function(choice, idx)
    if not choice or not idx then return end
    local session = sessions[idx]
    if session then
      M.config.socket_path = session.socket
      vim.notify("Connected to pi at: " .. session.cwd, vim.log.levels.INFO)
    end
  end)
end

return M
