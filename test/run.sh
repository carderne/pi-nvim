#!/usr/bin/env bash
# Headless test suite for pi-nvim.
#
#   bash test/run.sh
#
# Runs each spec in its own headless Neovim with an isolated socket directory
# (PI_NVIM_SOCKETS_DIR), so no real pi session is touched and nothing is left
# behind in /tmp/pi-nvim-sockets. The extension's own push protocol is checked
# with node, outside Neovim.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export PI_NVIM_SOCKETS_DIR="$work/sockets"
mkdir -p "$PI_NVIM_SOCKETS_DIR"

# A spec that errors before its own `qa!`/`cquit` leaves headless Neovim waiting
# for input forever, so bound each run and turn a load error into a failure.
run_spec() {
	local spec="$1"
	echo "== $spec =="
	timeout 60 nvim --headless -u "$root/test/minimal_init.vim" \
		-c "lua local ok, err = pcall(vim.cmd, 'luafile $root/test/$spec.lua'); if not ok then io.stderr:write('spec error: ' .. tostring(err) .. '\n'); vim.cmd('cquit 1') end" \
		-c 'qa!'
}

status=0
for spec in classify_spec sessions_spec prompt_spec commands_spec ui_spec notify_spec; do
	if ! run_spec "$spec"; then
		status=1
	fi
done

# The server side of the bridge is the pi extension, not Lua.
if ! node "$root/test/server_spec.mjs"; then
	status=1
fi

if [ "$status" -eq 0 ]; then
	echo "all specs passed"
else
	echo "specs failed"
fi
exit "$status"
