// Self-check for the push side of the bridge: subscribe, then broadcast.
import assert from "node:assert/strict";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";

const socketsDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-nvim-server-"));
process.env.PI_NVIM_SOCKETS_DIR = socketsDir;

const handlers = new Map();
const { default: install } = await import("../index.ts");
install({ on: (name, fn) => handlers.set(name, fn), registerCommand: () => {} });

const cwd = fs.mkdtempSync(path.join(os.tmpdir(), "pi-nvim-cwd-"));
await handlers.get("session_start")({}, { cwd, ui: { notify: () => {} } });

const sockPath = path.join(
	socketsDir,
	fs.readdirSync(socketsDir).find((name) => name.endsWith(".sock")),
);

function connect() {
	return new Promise((resolve, reject) => {
		const sock = net.createConnection(sockPath, () => resolve(sock));
		sock.once("error", reject);
	});
}

/** Collects newline-delimited lines and lets a test await the next one. */
function lines(sock) {
	const queue = [];
	const waiters = [];
	let buf = "";
	sock.on("data", (chunk) => {
		buf += chunk.toString();
		let nl = buf.indexOf("\n");
		while (nl !== -1) {
			queue.push(JSON.parse(buf.slice(0, nl)));
			buf = buf.slice(nl + 1);
			nl = buf.indexOf("\n");
		}
		while (queue.length && waiters.length) waiters.shift()(queue.shift());
	});
	return { next: () => (queue.length ? Promise.resolve(queue.shift()) : new Promise((r) => waiters.push(r))), queue };
}

const subscriber = await connect();
const sub = lines(subscriber);
subscriber.write('{"type":"subscribe"}\n');
assert.deepEqual(await sub.next(), { ok: true, type: "subscribed" });

const plain = await connect();
const plainLines = lines(plain);
plain.write('{"type":"ping"}\n');
assert.deepEqual(await plainLines.next(), { ok: true, type: "pong" });

handlers.get("agent_settled")();
assert.deepEqual(await sub.next(), { type: "agent_settled" });
await new Promise((r) => setTimeout(r, 100));
assert.deepEqual(plainLines.queue, [], "a plain connection receives no pushed events");

// A subscriber that vanishes before pi writes must not take the process down.
const doomed = await connect();
const doomedLines = lines(doomed);
doomed.on("error", () => {});
doomed.write('{"type":"subscribe"}\n');
await doomedLines.next();
doomed.destroy();
handlers.get("agent_settled")();
// The live subscriber still gets it, and the dead one must not throw.
assert.deepEqual(await sub.next(), { type: "agent_settled" });
await new Promise((r) => setTimeout(r, 100));

await handlers.get("session_shutdown")({ reason: "quit" });
assert.deepEqual(await sub.next(), { type: "session_shutdown", reason: "quit" });

// The session is gone: pushing again must not throw.
handlers.get("agent_settled")();

subscriber.destroy();
plain.destroy();
fs.rmSync(socketsDir, { recursive: true, force: true });
fs.rmSync(cwd, { recursive: true, force: true });
console.log("ok   - server push protocol");
