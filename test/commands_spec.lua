--- Spec for the `:Pi` / `:PiSend` ex-commands: they must accept arguments
--- instead of raising `E488: Trailing characters`.
---
--- Regression guard for the report "typed /settings, got E488": the commands
--- were created without `nargs`, so `:Pi /settings` was an error rather than a
--- prompt that gets routed like any other.
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

-- Nothing may talk to a real socket or open a real dialog.
local notices = {}
local sent = {}
local dialogs = {}
local original_notify = vim.notify
local original_send_raw = pi.send_raw
local original_socket_path = pi.config.socket_path
local ui = require("pi-nvim.ui")
local original_ui_open = ui.open

vim.notify = function(msg, level)
	notices = { msg = msg, level = level }
end

pi.send_raw = function(msg, cb)
	table.insert(sent, msg)
	if cb then cb(nil, { ok = true }) end
end

ui.open = function(opts)
	table.insert(dialogs, opts or {})
end

pi.config.socket_path = "/tmp/pi-nvim-spec.sock"
pi.setup({ set_default_keymaps = false })

local function reset()
	notices = {}
	sent = {}
	dialogs = {}
end

local function last_notice()
	return notices.msg or ""
end

local function run(cmd)
	local ok, err = pcall(vim.cmd, cmd)
	check(("`:%s` does not raise"):format(cmd), ok, err)
	return ok, err
end

-- 1. The reported gesture: a slash command typed as an argument.
reset()
run("Pi /settings")
eq("a builtin typed as an :Pi argument is not sent over the socket", #sent, 0)
check("it is reported as a builtin", last_notice():find("built%-in") ~= nil, last_notice())
check("the notice names the command", last_notice():find("/settings", 1, true) ~= nil, last_notice())
eq("a builtin argument never opens the dialog", #dialogs, 0)

-- 2. An expandable command as an argument expands instead of being prompted.
reset()
run("Pi /skill:graphify")
eq("an expandable argument is sent once", #sent, 1)
eq("an expandable argument asks for expansion", sent[1] and sent[1].expandPromptTemplates, true)
eq("the expandable text is forwarded unchanged", sent[1] and sent[1].message, "/skill:graphify")

-- 3. A plain prompt keeps every word and its spacing.
reset()
run("Pi explain  this   line")
eq("a plain argument is sent once", #sent, 1)
eq("a plain argument keeps its spacing", sent[1] and sent[1].message, "explain  this   line")
eq("a plain argument is not expanded", sent[1] and sent[1].expandPromptTemplates, nil)

-- 4. `:PiSend` behaves the same way.
reset()
run("PiSend /settings")
eq(":PiSend with a builtin sends nothing", #sent, 0)
check(":PiSend with a builtin warns", last_notice():find("built%-in") ~= nil, last_notice())

reset()
run("PiSend /skill:graphify")
eq(":PiSend with an expandable command sends once", #sent, 1)
eq(":PiSend expands", sent[1] and sent[1].expandPromptTemplates, true)

-- 5. No arguments still opens the dialog.
reset()
run("Pi")
eq("a bare :Pi opens the dialog", #dialogs, 1)
eq("a bare :Pi sends nothing", #sent, 0)

-- 6. The commands advertise `nargs = "*"`, so completion and `:Pi ...` agree.
local cmds = vim.api.nvim_get_commands({})
eq(":Pi accepts arguments", cmds.Pi and cmds.Pi.nargs, "*")
eq(":PiSend accepts arguments", cmds.PiSend and cmds.PiSend.nargs, "*")

vim.notify = original_notify
pi.send_raw = original_send_raw
ui.open = original_ui_open
pi.config.socket_path = original_socket_path

io.write(string.format("\n%d checks, %d failures\n", checks, failures))
if failures > 0 then
	vim.cmd("cquit 1")
end
