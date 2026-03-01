import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import * as net from "node:net";
import * as fs from "node:fs";
import * as path from "node:path";
import * as crypto from "node:crypto";

/**
 * nvim-bridge: Exposes a unix socket so external tools (like a neovim plugin)
 * can send prompts/context into a running interactive pi session.
 *
 * Protocol: newline-delimited JSON over a unix socket.
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
 * Socket path: /tmp/pi-nvim-<hash-of-cwd>.sock
 * A symlink at /tmp/pi-nvim-latest.sock always points to the most recently
 * started session, so neovim can just connect there if there's only one.
 *
 * The socket path for a given cwd is also written to /tmp/pi-nvim-sockets/<hash>
 * as a plain text file containing the cwd, so neovim can list all running sessions.
 */

function cwdHash(cwd: string): string {
  return crypto.createHash("md5").update(cwd).digest("hex").slice(0, 12);
}

function getSocketPath(cwd: string): string {
  return path.join(SOCKETS_DIR, `${cwdHash(cwd)}.sock`);
}

const SOCKETS_DIR = "/tmp/pi-nvim-sockets";
const LATEST_LINK = "/tmp/pi-nvim-latest.sock";

export default function (pi: ExtensionAPI) {
  let server: net.Server | null = null;
  let socketPath: string | null = null;

  pi.on("session_start", async (_event, ctx) => {
    const cwd = ctx.cwd;
    // Ensure sockets directory exists
    try { fs.mkdirSync(SOCKETS_DIR, { recursive: true }); } catch {}

    socketPath = getSocketPath(cwd);

    // Clean up stale socket
    try {
      fs.unlinkSync(socketPath);
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
      // Update latest symlink
      try {
        fs.unlinkSync(LATEST_LINK);
      } catch {}
      try {
        fs.symlinkSync(socketPath, LATEST_LINK);
      } catch {}

      // Register in sockets directory for discovery
      try {
        fs.mkdirSync(SOCKETS_DIR, { recursive: true });
        // Write a manifest file alongside the socket for discovery
        fs.writeFileSync(socketPath + ".info", JSON.stringify({ cwd, pid: process.pid }));
      } catch {}

      ctx.ui.notify(`nvim-bridge listening on ${socketPath}`, "info");
    });

    server.on("error", (err) => {
      ctx.ui.notify(`nvim-bridge error: ${err.message}`, "error");
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
        pi.sendUserMessage(msg.message);
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
    if (socketPath) {
      try { fs.unlinkSync(socketPath); } catch {}
      try {
        // Clean up latest symlink if it points to us
        const target = fs.readlinkSync(LATEST_LINK);
        if (target === socketPath) fs.unlinkSync(LATEST_LINK);
      } catch {}
      try {
        fs.unlinkSync(socketPath + ".info");
      } catch {}
    }
  }

  pi.on("session_shutdown", async () => {
    cleanup();
  });

  // Also clean up on process exit
  process.on("exit", cleanup);

  pi.registerCommand("nvim-bridge-info", {
    description: "Show nvim-bridge socket path",
    handler: async (_args, ctx) => {
      if (socketPath) {
        ctx.ui.notify(`Socket: ${socketPath}`, "info");
      } else {
        ctx.ui.notify("nvim-bridge not active", "warning");
      }
    },
  });
}
