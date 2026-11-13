--- Unit spec for the notification watcher: the client subscribes over a socket
--- and turns pushed events into vim.notify calls. Runs against a fake pi server
--- in the throwaway directory from test/run.sh.
local pi = require("pi-nvim")

local failures = 0
local checks = 0

local function check(label, cond, extra)
	checks = checks + 1
	if cond then
		io.write("ok   - " .. label .. "\n")
	else
		failures = failures + 1
		io.write("FAIL - " .. label .. (extra and (" :: " .. tostring(extra)) or "") .. "\n")
	end
end

local function eq(label, actual, expected)
	check(label, actual == expected, "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

local dir = assert(vim.env.PI_NVIM_SOCKETS_DIR, "PI_NVIM_SOCKETS_DIR must be set by test/run.sh")
local cwd = assert(vim.uv.cwd(), "cannot determine cwd")
local sock_path = dir .. "/spec-notify.sock"

-- Fake pi: accept one connection, record the subscribe message, then emit events.
local server = assert(vim.uv.new_pipe(false))
assert(server:bind(sock_path))
local peer
local subscribed = false
server:listen(16, function(err)
	if err then return end
	local client = vim.uv.new_pipe(false)
	server:accept(client)
	peer = client
	client:read_start(function(read_err, data)
		if read_err or not data then return end
		if data:find('"subscribe"', 1, true) then subscribed = true end
	end)
end)

-- Manifest so pi.get_socket_path() discovers this fake session in our cwd.
local fd = assert(io.open(sock_path .. ".info", "w"))
fd:write(vim.json.encode({
	socket = sock_path,
	cwd = cwd,
	pid = vim.uv.os_getpid(),
	startedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
}))
fd:close()

-- Capture notifications instead of writing to the headless UI.
local notes = {}
vim.notify = function(msg, level)
	notes[#notes + 1] = { msg = msg, level = level }
end

pi.setup({ notify = true })

check("the client subscribes", vim.wait(2000, function() return subscribed end), "no subscribe line")

peer:write('{"type":"agent_settled"}\n')
check("agent_settled is delivered", vim.wait(2000, function() return #notes >= 1 end), vim.inspect(notes))
eq("task finished text", notes[1] and notes[1].msg, "pi: task finished")
eq("task finished level", notes[1] and notes[1].level, vim.log.levels.INFO)

peer:write('{"type":"session_shutdown","reason":"quit"}\n')
check("session_shutdown is delivered", vim.wait(2000, function() return #notes >= 2 end), vim.inspect(notes))
eq("stopped text", notes[2] and notes[2].msg, "pi: session stopped (quit)")
eq("stopped level", notes[2] and notes[2].level, vim.log.levels.WARN)

pi.stop()
pcall(function()
	peer:close()
	server:close()
end)
os.remove(sock_path)
os.remove(sock_path .. ".info")

io.write(string.format("\n%d checks, %d failures\n", checks, failures))
if failures > 0 then
	vim.cmd("cquit 1")
end
