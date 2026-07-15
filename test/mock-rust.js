#!/usr/bin/env node
"use strict";
// Mock RustDedicated for wrapper e2e tests:
//  - writes console output to the -logfile (truncates it, like Unity)
//  - serves WebRCON: real RFC6455 handshake + masked-frame parsing (hand-rolled,
//    so the wrapper's native WebSocket client is exercised for real)
//  - broadcasts unsolicited frames the wrapper MUST NOT print (dup-stream test)
//  - quits on rcon "quit", stdin "quit", SIGTERM  (--ignore-quit disables the
//    first two, for shutdown-escalation tests)

const fs = require("fs");
const net = require("net");
const crypto = require("crypto");

const argv = process.argv.slice(2);
const argAfter = (k) => { const i = argv.indexOf(k); return i !== -1 ? argv[i + 1] : null; };
const LOG = argAfter("-logfile") || "mock.log";
const PORT = parseInt(argAfter("+rcon.port") || "28016", 10);
const PASS = argAfter("+rcon.password") || "";
const IGNORE_QUIT = argv.includes("--ignore-quit");

const log = fs.createWriteStream(LOG, { flags: "w" }); // Unity truncates its logfile
const wl = (s) => log.write(s + "\n");

const clients = new Set();
function wsSend(sock, obj) {
  const p = Buffer.from(JSON.stringify(obj), "utf8");
  let h;
  if (p.length < 126) h = Buffer.from([0x81, p.length]);
  else { h = Buffer.alloc(4); h[0] = 0x81; h[1] = 126; h.writeUInt16BE(p.length, 2); }
  try { sock.write(Buffer.concat([h, p])); } catch {}
}
function quitNow() {
  wl("Saving 0 entities");
  wl("Saving complete");
  setTimeout(() => process.exit(0), 200);
}

const server = net.createServer((sock) => {
  let buf = Buffer.alloc(0), shook = false;
  sock.on("data", (d) => {
    buf = Buffer.concat([buf, d]);
    if (!shook) {
      const idx = buf.indexOf("\r\n\r\n");
      if (idx === -1) return;
      const head = buf.slice(0, idx).toString();
      buf = buf.slice(idx + 4);
      const path = (head.match(/^GET (\S+)/) || [])[1] || "";
      const keyM = head.match(/Sec-WebSocket-Key: *(.+)/i);
      const key = keyM ? keyM[1].trim() : null;
      if (!key || decodeURIComponent(path.slice(1)) !== PASS) {
        sock.end("HTTP/1.1 403 Forbidden\r\n\r\n");
        return;
      }
      const acc = crypto.createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
      sock.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
        `Sec-WebSocket-Accept: ${acc}\r\n\r\n`);
      shook = true;
      clients.add(sock);
      wl("[rcon] client connected");
    }
    while (buf.length >= 2) {
      const op = buf[0] & 0x0f, masked = (buf[1] & 0x80) !== 0;
      let len = buf[1] & 0x7f, off = 2;
      if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; }
      else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); off = 10; }
      const mlen = masked ? 4 : 0;
      if (buf.length < off + mlen + len) return;
      const mask = masked ? buf.slice(off, off + 4) : null;
      let pay = buf.slice(off + mlen, off + mlen + len);
      if (mask) { const u = Buffer.from(pay); for (let i = 0; i < u.length; i++) u[i] ^= mask[i % 4]; pay = u; }
      buf = buf.slice(off + mlen + len);
      if (op === 8) { try { sock.end(Buffer.from([0x88, 0])); } catch {} clients.delete(sock); return; }
      if (op === 9) { try { sock.write(Buffer.concat([Buffer.from([0x8a, pay.length]), pay])); } catch {} continue; }
      if (op !== 1) continue;
      let msg; try { msg = JSON.parse(pay.toString("utf8")); } catch { continue; }
      const cmd = String(msg.Message || "");
      wl("[rcon cmd] " + cmd);
      if (cmd === "quit") {
        wsSend(sock, { Identifier: msg.Identifier, Message: "quitting...", Type: "Generic" });
        if (!IGNORE_QUIT) quitNow();
        continue;
      }
      if (cmd === "status") {
        wsSend(sock, { Identifier: msg.Identifier, Message: "hostname: mock-rust\nplayers : 0 (0 max)", Type: "Generic" });
        continue;
      }
      wsSend(sock, { Identifier: msg.Identifier, Message: "echo: " + cmd, Type: "Generic" });
    }
  });
  sock.on("error", () => {});
  sock.on("close", () => clients.delete(sock));
});

// boot logs fire immediately (game process is "up"); RCON binds after an optional
// delay so tests can exercise "wrapper starts before RCON is listening"
const RCON_DELAY = parseInt(argAfter("--rcon-delay") || "0", 10);
wl("Bootstrapping ...");
setTimeout(() => wl("[Oxide] Loading extension Oxide.Rust"), 100);
setTimeout(() => wl("Server startup complete"), 300);
let _n = 0;
setInterval(() => wl("tick " + ++_n), 400).unref();
// unsolicited broadcast spam — the wrapper must NOT print these
setInterval(() => { for (const c of clients) wsSend(c, { Identifier: 0, Message: "SPAMLINE console noise", Type: "Generic" }); }, 250).unref();
setTimeout(() => {
  server.listen(PORT, "127.0.0.1", () => wl("[rcon] listening on " + PORT));
}, RCON_DELAY);

process.stdin.setEncoding("utf8");
let sb = "";
process.stdin.on("data", (t) => {
  sb += t;
  const ls = sb.split(/\r?\n/); sb = ls.pop();
  for (const l of ls) {
    wl("[stdin] " + l);
    if (l.trim() === "quit" && !IGNORE_QUIT) quitNow();
  }
});
process.on("SIGTERM", () => process.exit(0));
process.on("SIGINT", () => process.exit(0));
