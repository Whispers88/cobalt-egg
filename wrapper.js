#!/usr/bin/env node
/* eslint-disable no-console */
const { spawn } = require("node:child_process");
const { createWriteStream, existsSync, mkdirSync } = require("node:fs");
const { resolve, dirname } = require("node:path");
const { setTimeout: delay } = require("node:timers/promises");
const WebSocket = require("ws");

/**
 * Env / defaults
 */
const env = process.env;
const STARTUP_DONE_TOKEN = env.STARTUP_DONE_TOKEN || "Server startup complete";

const LATEST_LOG = env.LATEST_LOG || "latest.log";
const LOG_FILE = env.LOG_FILE || `logs/${new Date().toISOString().replace(/[:.]/g, "-")}.log`;

const CRASH_ARCHIVE = env.CRASH_ARCHIVE === "1";
const CRASH_PATH = env.CRASH_PATH || "/home/container/crashdumps";

const RCON_HOST = env.RCON_HOST || "127.0.0.1";
const RCON_PORT = parseInt(env.RCON_PORT || "28016", 10);
const RCON_PASS = env.RCON_PASS || "CHANGEME";

const SHUTDOWN_RCON_CMDS = (env.SHUTDOWN_RCON_CMDS || "").split(",").map(s => s.trim()).filter(Boolean);
const SHUTDOWN_CMDS = (env.SHUTDOWN_CMDS || "").split(",").map(s => s.trim()).filter(Boolean);

const WATCH_ENABLED = env.WATCH_ENABLED !== "0";
const HEARTBEAT_TIMEOUT_SEC = parseInt(env.HEARTBEAT_TIMEOUT_SEC || "120", 10);
const SHUTDOWN_TIMEOUT_SEC = parseInt(env.SHUTDOWN_TIMEOUT_SEC || "30", 10);

/**
 * Simple file logger to mirror stdout/stderr
 */
function makeStream(p) {
  const full = resolve(p);
  const dir = dirname(full);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  return createWriteStream(full, { flags: "a" });
}
const latestStream = makeStream(LATEST_LOG);
const consoleStream = makeStream(LOG_FILE);

function logLine(source, line) {
  const ts = new Date().toISOString();
  const msg = `[${ts}] [${source}] ${line}\n`;
  latestStream.write(msg);
  consoleStream.write(msg);
}

let lastHeartbeat = Date.now();
let started = false;

/**
 * RCON (WebRCON) helpers
 */
function webRconUrl() {
  // Rust WebRCON is plain ws on tcp RCON port.
  // Some setups require / or /rcon path; plain root works for stock server.
  return `ws://${RCON_HOST}:${RCON_PORT}/${RCON_PASS}`;
}

async function sendWebRconCommands(cmds, timeoutSec) {
  if (cmds.length === 0) return;
  return new Promise((resolvePromise) => {
    const url = webRconUrl();
    let done = false;
    const ws = new WebSocket(url, { handshakeTimeout: 4000 });

    const finish = (ok) => {
      if (done) return;
      done = true;
      try { ws.close(); } catch (_) {}
      resolvePromise(ok);
    };

    ws.on("open", async () => {
      let id = 1;
      for (const cmd of cmds) {
        const payload = JSON.stringify({
          Identifier: id++,
          Message: cmd,
          Name: "Server Console",
        });
        ws.send(payload);
        await delay(150); // tiny gap between commands
      }
      // wait a short grace period to let server act
      await delay(1000);
      finish(true);
    });

    ws.on("message", (data) => {
      // A reply means socket is healthy; we could parse JSON but not required here.
      try {
        const txt = data.toString("utf8");
        if (txt) logLine("RCON", txt.trim());
      } catch {}
    });

    ws.on("error", (err) => {
      logLine("RCON", `error: ${err.message}`);
      finish(false);
    });

    setTimeout(() => finish(false), timeoutSec * 1000);
  });
}

/**
 * Optional: run shell commands on shutdown
 */
async function runShellCommands(cmds, timeoutSec) {
  if (cmds.length === 0) return;
  for (const cmd of cmds) {
    await new Promise((res) => {
      const sh = spawn("bash", ["-lc", cmd], { stdio: ["ignore", "pipe", "pipe"] });
      const timer = setTimeout(() => {
        try { sh.kill("SIGKILL"); } catch {}
      }, timeoutSec * 1000);
      sh.stdout.on("data", (buf) => logLine("SH", buf.toString("utf8").trimEnd()));
      sh.stderr.on("data", (buf) => logLine("SH", buf.toString("utf8").trimEnd()));
      sh.on("close", () => { clearTimeout(timer); res(); });
    });
  }
}

/**
 * Crash archiver (tar.gz logs and last logs)
 */
async function archiveOnCrash(exitCode, signal) {
  if (!CRASH_ARCHIVE) return;
  try {
    const ts = new Date().toISOString().replace(/[:.]/g, "-");
    const out = resolve(CRASH_PATH, `crash-${ts}-code${exitCode}${signal ? "-sig" + signal : ""}.tar.gz`);
    const files = [LOG_FILE, LATEST_LOG].map(f => resolve(f));
    const tar = spawn("bash", ["-lc", `tar -czf "${out}" ${files.map(f => `"${f}"`).join(" ")} 2>/dev/null || true`], {
      stdio: "ignore",
    });
    await new Promise(res => tar.on("close", res));
    logLine("ARCHIVE", `Crash bundle written: ${out}`);
  } catch (e) {
    logLine("ARCHIVE", `archive failed: ${e.message}`);
  }
}

/**
 * Watchdog: bump heartbeat when the server logs lines, and optionally exit non-zero if stalled
 * (Pterodactyl/Wings will restart the container if your service is marked as crashed).
 */
function bumpHeartbeat() {
  lastHeartbeat = Date.now();
  if (!started) started = true;
}
setInterval(() => {
  if (!WATCH_ENABLED) return;
  if (!started) return;
  const age = (Date.now() - lastHeartbeat) / 1000;
  if (age > HEARTBEAT_TIMEOUT_SEC) {
    logLine("WATCH", `No heartbeat for ${Math.round(age)}s (> ${HEARTBEAT_TIMEOUT_SEC}). Exiting for restart.`);
    // Let Docker stop us; wrapper exits, tini forwards signals etc.
    process.exitCode = 111;
    // exit soon; allow finally handlers to run
    setTimeout(() => process.exit(111), 200);
  }
}, 5_000);

/**
 * Spawn RustDedicated via arguments from entrypoint (Pterodactyl passes them in)
 */
const argsIndex = process.argv.indexOf("--");
const childArgs = argsIndex >= 0 ? process.argv.slice(argsIndex + 1) : process.argv.slice(2);
if (childArgs.length === 0) {
  console.error("wrapper: no command provided (expected ./RustDedicated …)");
  process.exit(2);
}

logLine("WRAPPER", `Starting: ${childArgs.join(" ")}`);
const child = spawn(childArgs[0], childArgs.slice(1), {
  stdio: ["ignore", "pipe", "pipe"],
  env: process.env,
});

child.stdout.on("data", (buf) => {
  const text = buf.toString("utf8");
  process.stdout.write(text);
  text.split(/\r?\n/).forEach((line) => {
    if (!line) return;
    logLine("GAME", line);
    bumpHeartbeat();
    if (line.includes(STARTUP_DONE_TOKEN)) {
      logLine("WRAPPER", "Startup token observed.");
    }
  });
});

child.stderr.on("data", (buf) => {
  const text = buf.toString("utf8");
  process.stderr.write(text);
  text.split(/\r?\n/).forEach((line) => {
    if (!line) return;
    logLine("GAME-ERR", line);
    bumpHeartbeat();
  });
});

let shuttingDown = false;
async function gracefulShutdown(reason) {
  if (shuttingDown) return;
  shuttingDown = true;
  logLine("WRAPPER", `Shutdown requested (${reason}). Running RCON + shell hooks…`);

  try {
    if (SHUTDOWN_RCON_CMDS.length > 0) {
      await sendWebRconCommands(SHUTDOWN_RCON_CMDS, SHUTDOWN_TIMEOUT_SEC);
    }
  } catch (e) {
    logLine("WRAPPER", `RCON shutdown error: ${e.message}`);
  }

  try {
    if (SHUTDOWN_CMDS.length > 0) {
      await runShellCommands(SHUTDOWN_CMDS, SHUTDOWN_TIMEOUT_SEC);
    }
  } catch (e) {
    logLine("WRAPPER", `Shell shutdown error: ${e.message}`);
  }

  // If the game is still alive, ask it to quit nicely; if your RCON script already sent 'quit', this is redundant but harmless.
  try { child.kill("SIGINT"); } catch {}
}

process.on("SIGTERM", () => gracefulShutdown("SIGTERM"));
process.on("SIGINT", () => gracefulShutdown("SIGINT"));

child.on("close", async (code, signal) => {
  logLine("WRAPPER", `Child exited code=${code ?? "null"} signal=${signal ?? "null"}`);
  if (code && code !== 0) {
    await archiveOnCrash(code, signal);
  }
  // Flush logs then exit with child's code (or special watchdog code if set)
  latestStream.end();
  consoleStream.end();
  // tiny delay to flush streams
  setTimeout(() => process.exit(code ?? 0), 50);
});
