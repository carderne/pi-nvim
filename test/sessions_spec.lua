--- Unit spec for session discovery: manifest parsing, cwd filtering, pinning.
--- Works on fake manifests in the throwaway directory from test/run.sh.
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
local here = assert(vim.uv.cwd(), "cannot determine cwd")
local elsewhere = "/tmp/pi-nvim-spec-other-project"
local our_pid = vim.uv.os_getpid()

--- Create a fake session: a socket-ish file plus the .info manifest beside it.
--- @param name string unique base name
--- @param cwd string directory the fake pi claims to run in
--- @param pid number pid recorded in the manifest
local function make_session(name, cwd, pid)
	local socket_file = dir .. "/" .. name .. ".sock"
	local fd = assert(io.open(socket_file, "w"))
	fd:write("")
	fd:close()
	local info_path = socket_file .. ".info"
	fd = assert(io.open(info_path, "w"))
	fd:write(vim.json.encode({
		socket = socket_file,
		cwd = cwd,
		pid = pid,
		startedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}))
	fd:close()
	return socket_file
end

local function remove_session(socket_file)
	os.remove(socket_file .. ".info")
	os.remove(socket_file)
end

local function socket_for(cwd)
	for _, session in ipairs(pi.sessions()) do
		if session.cwd == cwd then return session.socket end
	end
	return nil
end

check("no sessions in the empty directory", #pi.sessions() == 0, vim.inspect(pi.sessions()))
eq("no socket when nothing is running", pi.get_socket_path(), nil)

local mine = make_session("spec-current", here, our_pid)
local foreign = make_session("spec-foreign", elsewhere, our_pid)

eq("the session in this directory is discovered", socket_for(here), mine)
eq("a foreign session is discovered too", socket_for(elsewhere), foreign)
eq("the current directory's session wins", pi.get_socket_path(), mine)

-- Even when the foreign session is newer, a prompt must not cross projects.
vim.uv.fs_utime(foreign, os.time() + 5, os.time() + 5)
eq("newer foreign session does not win", pi.get_socket_path(), mine)

-- Pinning (what :PiSessions does) is explicit, so there it may cross projects.
pi._pinned_socket = foreign
eq("a pinned session wins over cwd matching", pi.get_socket_path(), foreign)
check("pinning does not touch config", pi.config.socket_path == nil, vim.inspect(pi.config.socket_path))

-- A pin that no longer exists is dropped silently.
remove_session(foreign)
eq("a dead pin falls back to the cwd session", pi.get_socket_path(), mine)
eq("a dead pin is cleared", pi._pinned_socket, nil)

-- An explicit socket_path in config always wins, pins included.
pi.config.socket_path = "/tmp/pi-nvim-spec-explicit.sock"
pi._pinned_socket = mine
eq("config override beats discovery", pi.get_socket_path(), pi.config.socket_path)
pi.config.socket_path = nil
pi.unpin()
eq("unpin clears the pin", pi._pinned_socket, nil)

-- Sessions whose process is gone, or whose socket file vanished, are hidden.
local dead = make_session("spec-dead", here, 999999)
local orphan = make_session("spec-orphan", here, our_pid)
os.remove(orphan)
check("a dead pid is filtered out", socket_for(here) == mine, "dead=" .. tostring(dead))

-- With only foreign sessions left, there is no socket to send to (and the
-- caller is told to use :PiSessions instead of writing into another project).
remove_session(mine)
local lonely = make_session("spec-lonely", elsewhere, our_pid)
eq("a foreign-only directory has no socket", pi.get_socket_path(), nil)
check("but the foreign session is still listed", #pi.sessions() == 1, vim.inspect(pi.sessions()))

-- Cleanup so repeated runs start empty.
for _, session in ipairs(pi.sessions()) do
	remove_session(session.sock_file)
end
remove_session(dead)
remove_session(lonely)

io.write(string.format("\n%d checks, %d failures\n", checks, failures))
if failures > 0 then
	vim.cmd("cquit 1")
end
