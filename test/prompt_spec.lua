--- Spec for pi-nvim.prompt: routing of built-ins, expandable slash input and
--- plain prompts, plus the terminal fast path.
---
--- M.send_raw is stubbed, so nothing touches a socket; the terminal case uses a
--- real `cat` job so the bracketed-paste payload is observable in the buffer.
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

-- Record notifications and socket traffic instead of delivering them.
local notices = {}
local sent = {}
local original_notify = vim.notify
local original_send_raw = pi.send_raw

vim.notify = function(msg, level)
	notices = { msg = msg, level = level }
end

pi.send_raw = function(msg, cb)
	table.insert(sent, msg)
	if cb then cb(nil, { ok = true }) end
end

local function reset()
	notices = {}
	sent = {}
end

local function last_notice()
	return notices.msg or ""
end

-- No pi terminal exists in this Neovim, so every case exercises the socket path.

-- 1. A built-in command must not be sent to the model as literal text.
reset()
pi.prompt("/settings")
eq("a builtin is not sent over the socket", #sent, 0)
check("a builtin warns instead", last_notice():find("built%-in") ~= nil, last_notice())
check("the warning names the command", last_notice():find("/settings", 1, true) ~= nil, last_notice())
eq("the warning is a warning", notices.level, vim.log.levels.WARN)
check("a refused builtin does not claim execution", last_notice():find("Command executed", 1, true) == nil, last_notice())

-- 2. User bash mode is TUI-only too.
reset()
pi.prompt("!ls")
eq("bash mode is not sent over the socket", #sent, 0)
check("bash mode warns", last_notice():find("built%-in") ~= nil, last_notice())

-- 3. Skills/templates/extension commands are expandable: pi gets the flag.
reset()
pi.prompt("/skill:graphify")
eq("one message is sent", #sent, 1)
eq("the message is a prompt", sent[1] and sent[1].type, "prompt")
eq("the message text is unchanged", sent[1] and sent[1].message, "/skill:graphify")
eq("expansion is requested", sent[1] and sent[1].expandPromptTemplates, true)
eq("an expandable command reports execution", last_notice(), "Pi: Command executed")

-- 4. Plain text keeps the old wire format (no expansion flag).
reset()
pi.prompt("hello there")
eq("one message is sent", #sent, 1)
eq("the message text is unchanged", sent[1] and sent[1].message, "hello there")
eq("no expansion flag for plain text", sent[1] and sent[1].expandPromptTemplates, nil)
eq("plain text reports a sent prompt", last_notice(), "Pi: Prompt sent")

-- 5. Paths that merely start with a slash stay prompts.
reset()
pi.prompt("/etc/hosts")
eq("a path is sent as a prompt", #sent, 1)
eq("a path is not flagged for expansion", sent[1] and sent[1].expandPromptTemplates, nil)
eq("a path still reports a sent prompt", last_notice(), "Pi: Prompt sent")

-- 7. A command whose attached context had to be dropped says so, once.
reset()
pi.prompt("/plan start", { context_dropped = true })
eq("the command still goes over the socket", sent[1] and sent[1].message, "/plan start")
eq("the notice reports the drop", last_notice(), "Pi: Command executed (context not sent)")

-- 8. Asking for input notifies nothing.
reset()
local original_input = vim.ui.input
vim.ui.input = function() end
pi.prompt(nil)
vim.ui.input = original_input
eq("an empty prompt notifies nothing", last_notice(), "")

-- 6. With a pi terminal loaded, everything is typed into it and never sent
--    over the socket (that is what keeps built-ins working).
local job = vim.fn.jobstart({ "cat" }, { term = true })
if job <= 0 then
	check("could not start the probe terminal job", false, job)
else
	local buf = vim.fn.bufnr("$")
	vim.api.nvim_buf_set_name(buf, "term://spec//1:pi")

	-- Built-in: typed into the terminal.
	reset()
	pi.prompt("/settings")
	eq("a builtin does not go over the socket when a terminal exists", #sent, 0)
	eq("a builtin typed into the terminal reports execution", last_notice(), "Pi: Command executed")

	local function wait_for_text(needle)
		return vim.wait(3000, function()
			for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
				if line:find(needle, 1, true) then return true end
			end
			return false
		end, 20)
	end

	check("the command reached the terminal", wait_for_text("/settings"))

	-- Plain prompt: also typed into the terminal.
	reset()
	pi.prompt("written-to-terminal")
	eq("a prompt does not go over the socket when a terminal exists", #sent, 0)
	check("the prompt reached the terminal", wait_for_text("written-to-terminal"))
	eq("a prompt typed into the terminal reports a sent prompt", last_notice(), "Pi: Prompt sent")

	vim.fn.jobstop(job)
end

vim.notify = original_notify
pi.send_raw = original_send_raw

io.write(string.format("\n%d checks, %d failures\n", checks, failures))
if failures > 0 then
	vim.cmd("cquit 1")
end
