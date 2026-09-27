import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { Message } from "@earendil-works/pi-ai";
import { uuidv7 } from "@earendil-works/pi-ai";
import * as net from "node:net";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as crypto from "node:crypto";

/**
 * pi-nvim: exposes a socket so external tools (like a Neovim plugin) can send
 * prompts/context into a running interactive Pi session.
 *
 * Protocol: newline-delimited JSON over a socket.
 *
 * Commands:
 *   { "type": "prompt", "message": "...", "images": [...]? }   fire-and-forget
 *   { "type": "ping" }
 *   { "id": "...", "type": "request", "method": "...", "params": {...} }
 *
 * Responses:
 *   { "ok": true }
 *   { "ok": true, "type": "pong" }
 *   { "id": "...", "ok": true,  "result": {...} }
 *   { "id": "...", "ok": false, "error": { "code": "...", "message": "..." } }
 *
 * Methods (namespaced):
 *   - "rpc.capabilities" -> { protocol, methods }
 *   - "llm.complete"     -> { text, model }   isolated model call, no tools
 *
 * pi-nvim only exposes infrastructure. Business capabilities (for example
 * "describe this jj change") live in the plugins that consume it.
 *
 * One connection per request. The client timeout is NOT cancellation: the
 * server may keep working after the client stops waiting. See README.md.
 *
 * Unix: unix socket at /tmp/pi-nvim-sockets/<hash>-<pid>.sock, a symlink at
 * /tmp/pi-nvim-latest.sock, and a .info manifest next to each socket.
 * Windows: unix sockets don't exist, so bind a named pipe
 * \\.\pipe\pi-nvim-<hash>-<pid> instead. The manifest (.info) lives in
 * %TEMP%/pi-nvim-sockets together with a marker <hash>-<pid>.sock file so the
 * nvim side can stat for liveness; the JSON carries the connect address in
 * "socket". The nvim plugin computes the same dir from TEMP (see sockets_dir()).
 */

const PROTOCOL = 1;

/** Safety cap for a single llm.complete call. Aborts the server-side call. */
const COMPLETE_TIMEOUT_MS = 120000;

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

// ============================================================================
// RPC methods
// ============================================================================

interface RpcError {
  code: string;
  message: string;
}

class RpcFailure extends Error {
  code: string;

  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

type RpcMethod = (params: any, ctx: ExtensionContext) => Promise<unknown>;

const METHODS = new Map<string, RpcMethod>();

function extractText(content: unknown): string {
  if (!Array.isArray(content)) return "";
  const parts: string[] = [];
  for (const block of content) {
    if (
      block &&
      typeof block === "object" &&
      (block as { type?: string }).type === "text" &&
      typeof (block as { text?: string }).text === "string"
    ) {
      parts.push((block as { text: string }).text);
    }
  }
  return parts.join("\n");
}

METHODS.set("llm.complete", async (params: any, ctx: ExtensionContext) => {
  const systemPrompt = typeof params?.systemPrompt === "string" ? params.systemPrompt : undefined;
  const inputMessages = Array.isArray(params?.messages) ? params.messages : [];
  if (inputMessages.length === 0) {
    throw new RpcFailure("invalid_params", "messages must be a non-empty array");
  }

  // MVP: user messages only. Richer roles come later.
  const messages: Message[] = inputMessages.map((m: any) => {
    if (m?.role && m.role !== "user") {
      throw new RpcFailure("invalid_params", `unsupported message role: ${m.role}`);
    }
    const text = typeof m?.content === "string" ? m.content : "";
    if (!text) {
      throw new RpcFailure("invalid_params", "each message needs a string content");
    }
    return {
      role: "user",
      content: [{ type: "text", text }],
      timestamp: Date.now(),
    } as Message;
  });

  let model = ctx.model;
  if (
    params?.model &&
    typeof params.model.provider === "string" &&
    typeof params.model.id === "string"
  ) {
    model = ctx.modelRegistry.find(params.model.provider, params.model.id);
    if (!model) {
      throw new RpcFailure(
        "no_model",
        `model not found: ${params.model.provider}/${params.model.id}`,
      );
    }
  }
  if (!model) {
    throw new RpcFailure("no_model", "no model selected");
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), COMPLETE_TIMEOUT_MS);
  try {
    const response = await ctx.modelRegistry.complete(
      model,
      { systemPrompt, messages },
      { signal: controller.signal, sessionId: uuidv7(), cacheRetention: "none" },
    );

    if (response.errorMessage) {
      throw new RpcFailure("provider_error", response.errorMessage);
    }
    if (response.stopReason === "aborted") {
      throw new RpcFailure(
        controller.signal.aborted ? "timeout" : "aborted",
        "completion did not finish",
      );
    }

    return {
      text: extractText(response.content).trim(),
      model: `${model.provider}/${model.id}`,
    };
  } finally {
    clearTimeout(timer);
  }
});

METHODS.set("rpc.capabilities", async () => ({
  protocol: PROTOCOL,
  methods: [...METHODS.keys()],
}));

function toRpcError(error: unknown): RpcError {
  if (error instanceof RpcFailure) {
    return { code: error.code, message: error.message };
  }
  return { code: "internal", message: error instanceof Error ? error.message : String(error) };
}

export default function (pi: ExtensionAPI) {
  let server: net.Server | null = null;
  let socketPath: string | null = null;
  let markerFile: string | null = null;
  let manifest: Record<string, unknown> | null = null;
  let infoTimer: ReturnType<typeof setInterval> | null = null;
  let currentCtx: ExtensionContext | null = null;

  /**
   * (Re)write the discovery manifest. Safe to call repeatedly: the nvim side
   * relies on this file to enumerate sessions, and some environments clean
   * files out of /tmp, so we re-create it when it goes missing.
   */
  function writeManifest() {
    if (!markerFile || !manifest) return;
    try {
      fs.mkdirSync(SOCKETS_DIR, { recursive: true });
      // Windows: named pipes aren't visible in the filesystem, so leave a
      // marker file the nvim side can stat for liveness.
      if (IS_WIN) fs.writeFileSync(markerFile, "");
      // Write atomically so a reader never sees a truncated manifest.
      const tmp = `${markerFile}.info.tmp`;
      fs.writeFileSync(tmp, JSON.stringify(manifest));
      fs.renameSync(tmp, `${markerFile}.info`);
    } catch {}
  }

  pi.on("session_start", async (_event, ctx) => {
    const cwd = ctx.cwd;
    currentCtx = ctx;
    // Ensure sockets directory exists
    try {
      fs.mkdirSync(SOCKETS_DIR, { recursive: true });
    } catch {}

    socketPath = getSocketPath(cwd);
    markerFile = socketFilePath(cwd);
    manifest = {
      socket: socketPath,
      cwd,
      pid: process.pid,
      startedAt: new Date().toISOString(),
    };

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
          handleMessage(line, conn);
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
      writeManifest();
      // Self-heal: keep the manifest alive even if something deletes it.
      if (infoTimer) clearInterval(infoTimer);
      infoTimer = setInterval(() => {
        if (markerFile && !fs.existsSync(`${markerFile}.info`)) writeManifest();
      }, 5000);
      if (typeof infoTimer.unref === "function") infoTimer.unref();
    });

    server.on("error", (err) => {
      ctx.ui.notify(`pi-nvim error: ${err.message}`, "error");
    });
  });

  // Keep the stored context fresh so llm.complete uses the active model.
  pi.on("model_select", async (_event, ctx) => {
    currentCtx = ctx;
  });

  function handleMessage(raw: string, conn: net.Socket) {
    let msg: any;
    try {
      msg = JSON.parse(raw);
    } catch (e: any) {
      respond(conn, { ok: false, error: `Parse error: ${e.message}` });
      return;
    }

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

    if (msg.type === "request") {
      void handleRequest(msg, conn);
      return;
    }

    respond(conn, { ok: false, error: `Unknown command type: ${msg.type}` });
  }

  async function handleRequest(msg: any, conn: net.Socket) {
    const id = msg.id;

    if (typeof msg.method !== "string") {
      respond(conn, {
        id,
        ok: false,
        error: { code: "invalid_params", message: "missing method" },
      });
      return;
    }

    const handler = METHODS.get(msg.method);
    if (!handler) {
      respond(conn, {
        id,
        ok: false,
        error: { code: "unsupported_method", message: `Unknown method: ${msg.method}` },
      });
      return;
    }

    if (!currentCtx) {
      respond(conn, {
        id,
        ok: false,
        error: { code: "no_context", message: "no active Pi context" },
      });
      return;
    }

    try {
      const result = await handler(msg.params ?? {}, currentCtx);
      respond(conn, { id, ok: true, result });
    } catch (error) {
      respond(conn, { id, ok: false, error: toRpcError(error) });
    }
  }

  function respond(conn: net.Socket, obj: any) {
    try {
      conn.write(JSON.stringify(obj) + "\n");
    } catch {}
  }

  function cleanup() {
    if (infoTimer) {
      clearInterval(infoTimer);
      infoTimer = null;
    }
    manifest = null;
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
    try {
      if (markerFile) fs.unlinkSync(markerFile + ".info.tmp");
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
