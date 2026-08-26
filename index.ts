import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import * as net from "node:net";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as crypto from "node:crypto";

/**
 * pi-nvim: Exposes a socket so external tools (like a neovim plugin)
 * can send prompts/context into a running interactive pi session.
 *
 * Repo: https://github.com/carderne/pi-nvim
 *
 * Protocol: newline-delimited JSON over a socket.
 *
 * Commands:
 *   { "type": "prompt", "message": "..." }
 *   { "type": "prompt", "message": "...", "images": [...] }
 *   { "type": "ping" }
 *
 * Responses:
 *   { "ok": true }
 *   { "ok": true, "type": "pong" }
 *   { "ok": false, "error": "..." }
 *
 * Unix: unix socket at /tmp/pi-nvim-sockets/<hash>-<pid>.sock, a symlink at
 * /tmp/pi-nvim-latest.sock, and a .info manifest next to each socket.
 * Windows: unix sockets don't exist, so bind a named pipe
 * \\.\pipe\pi-nvim-<hash>-<pid> instead. The manifest (.info) lives in
 * %TEMP%/pi-nvim-sockets together with a marker <hash>-<pid>.sock file so the
 * nvim side can stat for liveness; the JSON carries the connect address in
 * "socket". The nvim plugin computes the same dir from TEMP (see sockets_dir()).
 */

function cwdHash(cwd: string): string {
  return crypto.createHash("md5").update(cwd).digest("hex").slice(0, 12);
}

const IS_WIN = process.platform === "win32";
const SOCKETS_DIR = IS_WIN ? path.join(os.tmpdir(), "pi-nvim-sockets") : "/tmp/pi-nvim-sockets";
// Windows has no symlinks here; discovery relies solely on the .info manifests.
const LATEST_LINK = IS_WIN ? null : "/tmp/pi-nvim-latest.sock";

function socketBase(cwd: string): string {
  return `${cwdHash(cwd)}-${process.pid}`;
}

/** Path of the socket file (unix) or the liveness marker file (Windows). */
function socketFilePath(cwd: string): string {
  return path.join(SOCKETS_DIR, `${socketBase(cwd)}.sock`);
}

/** Actual listen address: a unix socket path or a Windows named pipe. */
function getSocketPath(cwd: string): string {
  return IS_WIN ? `\\\\.\\pipe\\pi-nvim-${socketBase(cwd)}` : socketFilePath(cwd);
}

export default function (pi: ExtensionAPI) {
  let server: net.Server | null = null;
  let socketPath: string | null = null;
  let markerFile: string | null = null;

  pi.on("session_start", async (_event, ctx) => {
    const cwd = ctx.cwd;
    // Ensure sockets directory exists
    try {
      fs.mkdirSync(SOCKETS_DIR, { recursive: true });
    } catch {}

    socketPath = getSocketPath(cwd);
    markerFile = socketFilePath(cwd);

    // Clean up stale socket/marker
    try {
      fs.unlinkSync(socketPath);
    } catch {}
    try {
      fs.unlinkSync(markerFile);
    } catch {}

    server = net.createServer((conn) => {
      let buffer = "";
      conn.on("data", (data) => {
        buffer += data.toString();
        let newlineIdx: number;
        while ((newlineIdx = buffer.indexOf("\n")) !== -1) {
          const line = buffer.slice(0, newlineIdx).trim();
          buffer = buffer.slice(newlineIdx + 1);
          if (!line) continue;
          handleMessage(line, conn, cwd);
        }
      });
      conn.on("error", () => {});
    });

    server.listen(socketPath, () => {
      // Update latest symlink (unix only)
      if (LATEST_LINK) {
        try {
          fs.unlinkSync(LATEST_LINK);
        } catch {}
        try {
          fs.symlinkSync(socketPath!, LATEST_LINK);
        } catch {}
      }

      // Register in sockets directory for discovery
      try {
        fs.mkdirSync(SOCKETS_DIR, { recursive: true });
        // Windows: named pipes aren't visible in the filesystem, so leave a
        // marker file the nvim side can stat for liveness.
        if (IS_WIN) fs.writeFileSync(markerFile!, "");
        fs.writeFileSync(
          markerFile! + ".info",
          JSON.stringify({
            socket: socketPath,
            cwd,
            pid: process.pid,
            startedAt: new Date().toISOString(),
          }),
        );
      } catch {}
    });

    server.on("error", (err) => {
      ctx.ui.notify(`pi-nvim error: ${err.message}`, "error");
    });
  });

  function handleMessage(raw: string, conn: net.Socket, _cwd: string) {
    try {
      const msg = JSON.parse(raw);

      if (msg.type === "ping") {
        respond(conn, { ok: true, type: "pong" });
        return;
      }

      if (msg.type === "prompt" && typeof msg.message === "string") {
        // Exit kitty's scrollback viewer by switching to private screen mode
        // and back. This snaps to the bottom without clearing scrollback history.
        process.stdout.write("\x1b[?1049h\x1b[?1049l");
        pi.sendUserMessage(msg.message, { deliverAs: "followUp" });
        respond(conn, { ok: true });
        return;
      }

      respond(conn, { ok: false, error: `Unknown command type: ${msg.type}` });
    } catch (e: any) {
      respond(conn, { ok: false, error: `Parse error: ${e.message}` });
    }
  }

  function respond(conn: net.Socket, obj: any) {
    try {
      conn.write(JSON.stringify(obj) + "\n");
    } catch {}
  }

  function cleanup() {
    if (server) {
      server.close();
      server = null;
    }
    if (!socketPath) return;
    try {
      fs.unlinkSync(socketPath);
    } catch {}
    try {
      if (markerFile) fs.unlinkSync(markerFile);
    } catch {}
    try {
      // Clean up latest symlink if it points to us (unix only)
      if (LATEST_LINK) {
        const target = fs.readlinkSync(LATEST_LINK);
        if (target === socketPath) fs.unlinkSync(LATEST_LINK);
      }
    } catch {}
    try {
      if (markerFile) fs.unlinkSync(markerFile + ".info");
    } catch {}
  }

  pi.on("session_shutdown", async () => {
    cleanup();
  });

  // Also clean up on process exit
  process.on("exit", cleanup);

  pi.registerCommand("pi-nvim-info", {
    description: "Show pi-nvim socket path",
    handler: async (_args, ctx) => {
      if (socketPath) {
        ctx.ui.notify(`Socket: ${socketPath}`, "info");
      } else {
        ctx.ui.notify("pi-nvim not active", "warning");
      }
    },
  });
}
