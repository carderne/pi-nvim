#!/usr/bin/env bash
#
# Smoke test for pi-nvim RPC.
#
# It starts a throwaway `pi --mode rpc` session with this repo's extension and
# drives it from a headless Neovim using this repo's Lua module. It does not
# touch your running sessions or your settings.
#
# Usage:
#   scripts/smoke.sh              # protocol only (no tokens)
#   WITH_MODEL=1 scripts/smoke.sh # also llm.complete (uses the active model)
#   FORK=/path/to/pi-nvim scripts/smoke.sh  # override the repo root
#
# Exit status: 0 when every check passes, 1 otherwise.
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORK="${FORK:-$(cd "$SCRIPT_DIR/.." && pwd)}"

if [ ! -f "$FORK/index.ts" ] || [ ! -f "$FORK/lua/pi-nvim/init.lua" ]; then
  echo "FORK does not look like the pi-nvim repo: $FORK" >&2
  exit 1
fi

WORK="$(mktemp -d)"
FIFO="$WORK/fifo"
OUT="$WORK/out.txt"
mkfifo "$FIFO"

PIPID=""
FEEDER=""
cleanup() {
  [ -n "$PIPID" ] && kill "$PIPID" 2>/dev/null
  [ -n "$FEEDER" ] && kill "$FEEDER" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

cd "$WORK" || exit 1
sleep 300 > "$FIFO" & FEEDER=$!
pi --mode rpc --no-session --no-extensions --extension "$FORK/index.ts" < "$FIFO" >/dev/null 2>"$WORK/pi.err" & PIPID=$!

# Wait for OUR session manifest (matching this cwd), not just any manifest.
for _ in $(seq 1 80); do
  grep -l "\"cwd\":\"$WORK\"" /tmp/pi-nvim-sockets/*.info >/dev/null 2>&1 && break
  sleep 0.5
done

cat > "$WORK/test.lua" <<'LUA'
vim.opt.rtp:prepend(os.getenv("FORK"))
local pi = require("pi-nvim")
local lines = {}
local failed = 0

-- Records PASS/FAIL and keeps going, so one failure still shows the full report.
local function CHECK(name, ok, detail)
  lines[#lines + 1] = string.format("%-16s %s%s", name, ok and "PASS" or "FAIL", detail and ("  (" .. detail .. ")") or "")
  if not ok then
    failed = failed + 1
  end
end

local done = 0
local target = os.getenv("WITH_MODEL") == "1" and 4 or 3

-- The extension answers and advertises protocol 1 with both methods.
pi.capabilities(function(e, c)
  local methods = (c and c.methods) or {}
  local has = {}
  for _, m in ipairs(methods) do
    has[m] = true
  end
  local ok = e == nil and c ~= nil and c.protocol == 1 and has["llm.complete"] and has["rpc.capabilities"]
  CHECK("capabilities", ok, e and (e.code .. ": " .. e.message) or (c and vim.json.encode(c) or "nil"))
  done = done + 1
end)

-- Unknown methods are rejected with a structured unsupported_method error.
pi.request("nope.nope", {}, function(e)
  CHECK("unknown method", e ~= nil and e.code == "unsupported_method", e and e.code or "nil")
  done = done + 1
end)

-- Empty messages are rejected with invalid_params (no model call).
pi.complete({ messages = {} }, function(e)
  CHECK("invalid params", e ~= nil and e.code == "invalid_params", e and e.code or "nil")
  done = done + 1
end)

-- A real model call returns non-empty text (only with WITH_MODEL=1).
if os.getenv("WITH_MODEL") == "1" then
  pi.complete({ systemPrompt = "Reply with exactly one word.", messages = { { role = "user", content = "Say hello" } } }, function(e, r)
    local ok = e == nil and r ~= nil and type(r.text) == "string" and #r.text > 0
    CHECK("llm.complete", ok, e and (e.code .. ": " .. e.message) or (r and ("text=" .. tostring(r.text)) or "nil"))
    done = done + 1
  end)
end

vim.wait(120000, function() return done >= target end, 200)
lines[#lines + 1] = ""
lines[#lines + 1] = failed == 0 and "RESULT: PASS" or ("RESULT: FAIL (" .. failed .. " failed)")

local f = io.open(os.getenv("OUT"), "w")
f:write(table.concat(lines, "\n") .. "\n")
f:close()
vim.cmd("qa!")
LUA

WITH_MODEL="${WITH_MODEL:-0}" OUT="$OUT" FORK="$FORK" nvim --headless -u NONE -c "luafile $WORK/test.lua" -c "qa!" 2>"$WORK/nvim.err"

echo "--- pi-nvim RPC smoke (WITH_MODEL=${WITH_MODEL:-0}) ---"
if [ -f "$OUT" ]; then
  cat "$OUT"
else
  echo "FAIL: no output from the test (Neovim likely failed to start)"
fi

if [ -s "$WORK/nvim.err" ]; then
  echo "--- nvim.err ---"
  cat "$WORK/nvim.err"
fi
if [ -s "$WORK/pi.err" ]; then
  echo "--- pi.err ---"
  cat "$WORK/pi.err"
fi

if grep -q "^RESULT: PASS" "$OUT" 2>/dev/null; then
  exit 0
fi
exit 1
