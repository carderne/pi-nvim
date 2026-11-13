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
 *   { "type": "prompt", "message": "...", "images": [{ "type": "image", "data": "<base64>", "mimeType": "image/png" }] }
 *   { "type": "prompt", "message": "/skill:foo", "expandPromptTemplates": true }
 *   { "type": "ping" }
 *   { "type": "subscribe" }   (keep the connection open for pushed events)
 *
 * expandPromptTemplates makes pi dispatch extension commands and expand
 * /skill:* and /template instead of sending the text to the model. pi's
 * built-in TUI commands (/settings, /model, …) cannot be dispatched this way:
 * the Neovim side types those into the pi terminal instead.
 *
 * Responses:
 *   { "ok": true }
 *   { "ok": true, "type": "pong" }
 *   { "ok": true, "type": "subscribed" }
 *   { "ok": false, "error": "..." }
 *
 * Pushed events (only on connections that sent subscribe):
 *   { "type": "agent_settled" }
 *   { "type": "session_shutdown", "reason": "quit" | "reload" | "new" | "resume" | "fork" }
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
// PI_NVIM_SOCKETS_DIR lets callers (tests, unusual setups) move the directory;
// the neovim plugin reads the same variable.
const SOCKETS_DIR =
  process.env.PI_NVIM_SOCKETS_DIR ||
  (IS_WIN ? path.join(os.tmpdir(), "pi-nvim-sockets") : "/tmp/pi-nvim-sockets");
// Windows has no symlinks here; discovery relies solely on the .info manifests.
const LATEST_LINK = IS_WIN ? null : "/tmp/pi-nvim-latest.sock";

/** Longest unterminated line we buffer before dropping the connection. */
const MAX_LINE_BYTES = 1024 * 1024;
/** Connections served at the same time. */
const MAX_CONNECTIONS = 32;
/** A client that sends nothing for this long is disconnected. */
const IDLE_TIMEOUT_MS = 30_000;
/** Manifests older than this are abandoned, whatever their pid says. */
const STALE_AFTER_MS = 7 * 24 * 60 * 60 * 1000;

const MANIFEST_SUFFIX = ".info";

interface Manifest {
  socket?: string;
  cwd?: string;
  pid?: number;
  startedAt?: string;
}

interface ImageContent {
  type: "image";
  data: string;
  mimeType: string;
}

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

function unlinkQuietly(target: string): void {
  try {
    fs.unlinkSync(target);
  } catch {}
}

function removeLatestLinkTo(target: string): void {
  if (!LATEST_LINK) return;
  try {
    if (fs.readlinkSync(LATEST_LINK) === target) unlinkQuietly(LATEST_LINK);
  } catch {}
}

function readManifest(infoPath: string): Manifest | null {
  try {
    const parsed = JSON.parse(fs.readFileSync(infoPath, "utf8"));
    return parsed && typeof parsed === "object" ? (parsed as Manifest) : null;
  } catch {
    return null;
  }
}

/** Does this pid still exist? EPERM means "yes, but not ours". */
function isPidAlive(pid: unknown): boolean {
  if (typeof pid !== "number" || !Number.isFinite(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (e: any) {
    return e?.code === "EPERM";
  }
}

/**
 * Remove manifests and sockets left behind by pi sessions that are gone
 * (killed, crashed, or long dead). Without this every dead session keeps
 * shadowing live ones during discovery.
 */
function pruneStaleSockets(): void {
  let entries: string[];
  try {
    entries = fs.readdirSync(SOCKETS_DIR);
  } catch {
    return;
  }

  const now = Date.now();
  for (const entry of entries) {
    if (!entry.endsWith(MANIFEST_SUFFIX)) continue;
    const infoPath = path.join(SOCKETS_DIR, entry);
    // "<base>.sock.info" → "<base>.sock" (unix socket, or Windows marker file)
    const socketFile = infoPath.slice(0, -MANIFEST_SUFFIX.length);
    const info = readManifest(infoPath);

    const startedAt = info?.startedAt ? Date.parse(info.startedAt) : NaN;
    const unreadable = info === null;
    const deadPid = typeof info?.pid === "number" && !isPidAlive(info.pid);
    const tooOld = Number.isFinite(startedAt) && now - startedAt > STALE_AFTER_MS;
    const orphaned = info !== null && !fs.existsSync(socketFile);

    if (!unreadable && !deadPid && !tooOld && !orphaned) continue;

    unlinkQuietly(infoPath);
    unlinkQuietly(socketFile);
    removeLatestLinkTo(socketFile);
  }
}

/**
 * Create the sockets directory and refuse to serve if it is not ours: another
 * user owning it could pre-create the socket paths we are about to bind.
 */
function ensureSocketsDir(): { ok: true } | { ok: false; reason: string } {
  try {
    fs.mkdirSync(SOCKETS_DIR, { recursive: true, mode: 0o700 });
  } catch (e: any) {
    return { ok: false, reason: `cannot create ${SOCKETS_DIR}: ${e?.message ?? e}` };
  }

  try {
    const stat = fs.statSync(SOCKETS_DIR);
    const uid = typeof process.getuid === "function" ? process.getuid() : null;
    if (uid !== null && stat.uid !== uid) {
      return { ok: false, reason: `${SOCKETS_DIR} is owned by uid ${stat.uid}, not ${uid}` };
    }
    fs.chmodSync(SOCKETS_DIR, 0o700);
  } catch (e: any) {
    return { ok: false, reason: `cannot inspect ${SOCKETS_DIR}: ${e?.message ?? e}` };
  }

  return { ok: true };
}

const EXIT_HANDLERS_KEY = Symbol.for("pi-nvim.exit-handlers");

/**
 * Run `fn` on process exit. The `exit` listener is installed once per process:
 * pi reloads extensions on /reload, and `process.on("exit", …)` in the module
 * body would pile up a listener (and a socket) per reload.
 */
function registerExitHandler(fn: () => void): void {
  const store = globalThis as unknown as Record<symbol, Set<() => void> | undefined>;
  let handlers = store[EXIT_HANDLERS_KEY];
  if (!handlers) {
    handlers = new Set<() => void>();
    store[EXIT_HANDLERS_KEY] = handlers;
    process.once("exit", () => {
      for (const handler of handlers ?? []) {
        try {
          handler();
        } catch {}
      }
    });
  }
  handlers.add(fn);
}

function unregisterExitHandler(fn: () => void): void {
  const store = globalThis as unknown as Record<symbol, Set<() => void> | undefined>;
  store[EXIT_HANDLERS_KEY]?.delete(fn);
}

function isImageContent(value: unknown): value is ImageContent {
  const candidate = value as Partial<ImageContent> | null;
  return (
    typeof candidate === "object" &&
    candidate !== null &&
    candidate.type === "image" &&
    typeof candidate.data === "string" &&
    typeof candidate.mimeType === "string"
  );
}

export default function (pi: ExtensionAPI) {
  let server: net.Server | null = null;
  let socketPath: string | null = null;
  let markerFile: string | null = null;
  let connections = 0;
  // Connections that sent {"type":"subscribe"}; they only receive pushed events.
  const listeners = new Set<net.Socket>();

  pi.on("session_start", async (_event, ctx) => {
    const cwd = ctx.cwd;

    const dir = ensureSocketsDir();
    if (!dir.ok) {
      ctx.ui.notify(`pi-nvim: refusing to open a socket, ${dir.reason}`, "error");
      return;
    }

    pruneStaleSockets();

    socketPath = getSocketPath(cwd);
    markerFile = socketFilePath(cwd);

    // Clean up stale socket/marker from a previous session in this cwd
    unlinkQuietly(socketPath);
    unlinkQuietly(markerFile);

    server = net.createServer((conn) => {
      if (connections >= MAX_CONNECTIONS) {
        conn.destroy();
        return;
      }
      connections += 1;

      // A client that connects and then goes silent must not hold a slot.
      conn.setTimeout(IDLE_TIMEOUT_MS, () => conn.destroy());

      let buffer = "";
      conn.on("data", (data) => {
        buffer += data.toString();
        if (buffer.length > MAX_LINE_BYTES) {
          // Never buffer an unbounded line: drop the client instead.
          buffer = "";
          conn.destroy();
          return;
        }
        let newlineIdx: number;
        while ((newlineIdx = buffer.indexOf("\n")) !== -1) {
          const line = buffer.slice(0, newlineIdx).trim();
          buffer = buffer.slice(newlineIdx + 1);
          if (!line) continue;
          handleMessage(line, conn);
        }
      });

      conn.on("close", () => {
        connections = Math.max(0, connections - 1);
        listeners.delete(conn);
      });
      conn.on("error", () => {});
    });

    // Wait for the listen callback before announcing the session: a client can
    // connect as soon as it sees the manifest, so session_start must not
    // resolve while the socket is still not accepting connections.
    try {
      await new Promise<void>((resolve, reject) => {
        const onListenError = (err: Error) => reject(err);
        server!.once("error", onListenError);
        server!.listen(socketPath!, () => {
          server!.off("error", onListenError);
          resolve();
        });
      });
    } catch (err: any) {
      ctx.ui.notify(`pi-nvim: cannot listen on ${socketPath}, ${err?.message ?? err}`, "error");
      server = null;
      return;
    }

    // Errors after a successful listen are reported, but must not crash pi.
    server.on("error", (err) => {
      ctx.ui.notify(`pi-nvim error: ${err.message}`, "error");
    });

    // Only the owner may talk to this socket.
    try {
      if (socketPath) fs.chmodSync(socketPath, 0o600);
    } catch {}

    // Update latest symlink (unix only)
    if (LATEST_LINK && socketPath) {
      unlinkQuietly(LATEST_LINK);
      try {
        fs.symlinkSync(socketPath, LATEST_LINK);
      } catch {}
    }

    // Register in sockets directory for discovery
    try {
      // Windows: named pipes aren't visible in the filesystem, so leave a
      // marker file the nvim side can stat for liveness.
      if (IS_WIN && markerFile) fs.writeFileSync(markerFile, "");
      if (markerFile) {
        fs.writeFileSync(
          markerFile + ".info",
          JSON.stringify({
            socket: socketPath,
            cwd,
            pid: process.pid,
            startedAt: new Date().toISOString(),
          }),
        );
      }
    } catch {}
  });

  function handleMessage(raw: string, conn: net.Socket) {
    try {
      const msg = JSON.parse(raw);

      if (msg.type === "ping") {
        respond(conn, { ok: true, type: "pong" });
        return;
      }

      if (msg.type === "subscribe") {
        listeners.add(conn);
        // A subscriber only receives; the idle timeout must not close it.
        conn.setTimeout(0);
        respond(conn, { ok: true, type: "subscribed" });
        return;
      }

      if (msg.type === "prompt" && typeof msg.message === "string") {
        // Exit kitty's scrollback viewer by switching to private screen mode
        // and back. This snaps to the bottom without clearing scrollback history.
        // Only meaningful when stdout is a terminal we can drive.
        if (process.stdout.isTTY) {
          process.stdout.write("\x1b[?1049h\x1b[?1049l");
        }

        const images: ImageContent[] = Array.isArray(msg.images)
          ? msg.images.filter(isImageContent)
          : [];
        const content =
          images.length > 0
            ? [{ type: "text" as const, text: msg.message }, ...images]
            : msg.message;

        pi.sendUserMessage(content, {
          deliverAs: "followUp",
          expandPromptTemplates: msg.expandPromptTemplates === true,
        });
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

  /** Push an event to every connection that subscribed. */
  function broadcast(obj: any) {
    const line = JSON.stringify(obj) + "\n";
    for (const conn of listeners) {
      try {
        conn.write(line);
      } catch {}
    }
  }

  pi.on("agent_settled", () => {
    broadcast({ type: "agent_settled" });
  });

  function cleanup() {
    // Subscribers only receive; end them so clients see EOF and reconnect to the
    // socket the next session creates (e.g. after /reload, same pid and path).
    for (const conn of listeners) {
      try {
        conn.end();
      } catch {}
    }
    listeners.clear();

    if (server) {
      server.close();
      server = null;
    }
    if (!socketPath) return;
    unlinkQuietly(socketPath);
    removeLatestLinkTo(socketPath);
    if (markerFile) {
      unlinkQuietly(markerFile);
      unlinkQuietly(markerFile + ".info");
    }
  }

  const exitCleanup = () => cleanup();
  registerExitHandler(exitCleanup);

  pi.on("session_shutdown", async (event) => {
    // Tell connected editors why the session is going away before the socket closes.
    broadcast({ type: "session_shutdown", reason: event.reason });
    // session_shutdown is the reliable path; the exit handler is only a backstop.
    unregisterExitHandler(exitCleanup);
    cleanup();
  });

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
