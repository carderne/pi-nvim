--- Unit spec for pi-nvim.classify_input: how a submitted line is routed.
--- No socket, no terminal.
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

-- Built-in pi TUI commands cannot be dispatched over the socket.
for _, cmd in ipairs({ "/settings", "/model", "/tree", "/thinking", "/resume", "/quit" }) do
	eq(cmd .. " is a builtin", pi.classify_input(cmd), "builtin")
end

-- User bash mode (! and !!) lives in the TUI too.
eq("!ls is a builtin", pi.classify_input("!ls"), "builtin")
eq("!!ls is a builtin", pi.classify_input("!!ls"), "builtin")

-- Anything else starting with a slash is left for pi to expand/dispatch.
eq("/skill:graphify is expandable", pi.classify_input("/skill:graphify"), "expandable")
eq("/template foo is expandable", pi.classify_input("/template foo"), "expandable")
eq("extension commands are expandable", pi.classify_input("/pi-nvim-info"), "expandable")

-- Ordinary prompts.
eq("plain text is a prompt", pi.classify_input("hello"), "prompt")
eq("an absolute path is a prompt", pi.classify_input("/etc/hosts"), "prompt")
eq("a bare slash is a prompt", pi.classify_input("/"), "prompt")
eq("empty input is a prompt", pi.classify_input(""), "prompt")
eq("nil input is a prompt", pi.classify_input(nil), "prompt")

-- Surrounding whitespace is ignored, the command name is still recognised.
eq("leading whitespace is ignored", pi.classify_input("   /model  "), "builtin")
eq("builtin matching is prefix based", pi.classify_input("/model foo"), "builtin")
eq("unknown command names are not builtins", pi.classify_input("/modelx"), "expandable")

io.write(string.format("\n%d checks, %d failures\n", checks, failures))
if failures > 0 then
	vim.cmd("cquit 1")
end
