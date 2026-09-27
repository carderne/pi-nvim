local M = {}

local function has_method(methods, name)
  for _, method in ipairs(methods or {}) do
    if method == name then return true end
  end
  return false
end

function M.check()
  vim.health.start("pi-nvim")

  -- Runtime
  if vim.uv then
    vim.health.ok("vim.uv (libuv) is available")
  else
    vim.health.error("vim.uv (libuv) is not available")
  end

  if vim.fn.executable("pi") == 1 then
    vim.health.ok("`pi` found on PATH: " .. vim.trim(vim.fn.system({ "pi", "--version" })))
  else
    vim.health.warn("`pi` not found on PATH")
  end

  local pi = require("pi-nvim")

  -- Sessions
  local sessions = pi.discover_sessions()
  if #sessions == 0 then
    vim.health.warn("no running pi sessions found")
  else
    vim.health.ok(string.format("%d pi session(s) found", #sessions))
    for _, session in ipairs(sessions) do
      vim.health.info(string.format("%s [pid %s] %s", session.cwd, session.pid, session.socket))
    end
  end

  local socket = pi.get_socket_path()
  if not socket then
    vim.health.warn("no session resolved for the current directory")
    return
  end
  vim.health.ok("session resolved: " .. socket)

  -- RPC capabilities (server side)
  local done, caps, cerr = false, nil, nil
  pi.capabilities(function(err, result)
    cerr = err
    caps = result
    done = true
  end, { timeout = 2000 })
  vim.wait(3000, function() return done end, 50)

  if not done then
    vim.health.error("RPC did not answer within 2s")
    return
  end

  if cerr then
    vim.health.error(string.format("RPC capabilities failed: %s: %s", cerr.code, cerr.message))
    if cerr.code == "unsupported_method" or (cerr.message or ""):find("Unknown command type") then
      vim.health.info("The running pi-nvim extension is older than this plugin. Restart pi with this repo's extension.")
    end
    return
  end

  vim.health.ok(string.format("RPC protocol %s", tostring(caps.protocol)))
  if has_method(caps.methods, "llm.complete") then
    vim.health.ok("llm.complete is available")
  else
    vim.health.error("llm.complete is not available (old pi-nvim extension?)")
  end
end

return M
