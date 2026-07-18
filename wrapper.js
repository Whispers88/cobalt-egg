#!/usr/bin/env node
"use strict";
// ============================================================================
// Cobalt wrapper 2.0 — logfile-read + WebRCON-send
//
//   read  = tail -F the Unity -logfile (injected into argv if missing).
//           Unity with -logfile writes nothing to stdout; the tail IS the console.
//   send  = one persistent WebRCON client (native WebSocket, Node >= 22).
//           Rust WebRCON broadcasts ALL console output to every client, so we
//           print ONLY responses whose Identifier matches a command we sent —
//           anything unsolicited would 100%-duplicate the logfile stream.
//   stop  = "quit" (Wings stop cmd) / SIGTERM / SIGINT ->
//           rcon quit -> (rcon down? stdin quit) -> SIGTERM -> SIGKILL,
//           waiting SHUTDOWN_TIMEOUT_SEC (default 60) for the save to finish.
//
// Panel input:
//   ! <sh>                  run shell in container
//   .help                   list commands
//   .version                installed build + framework + pin + catalog
//   .pin [buildid]          freeze updates on current (or given) build
//   .unpin                  resume updates on next boot
//   .rollback <build|last>  stage rollback (download now, applied at next boot)
//   .telemetry              game CPU/RSS + loadavg + disk
//   rcon: <x>               explicit rcon send
//   <anything else>         rcon send
// ============================================================================

const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");

// ---------- config ----------
const HOME = process.env.COBALT_HOME || "/home/container";
const COBALT_DIR = process.env.COBALT_DIR || path.join(HOME, ".cobalt");
const UNITY_LOG = process.env.UNITY_LOG || path.join(HOME, "unity.log");
const COBALT_LOG = process.env.COBALT_LOG || path.join(HOME, "cobalt.log");
const APPID = process.env.SRCDS_APPID || "258550";
const ACF = path.join(HOME, "steamapps", `appmanifest_${APPID}.acf`);

const RCON_HOST = process.env.RCON_HOST || "127.0.0.1";
const RCON_PORT = parseInt(process.env.RCON_PORT || "28016", 10);
const RCON_PASS = process.env.RCON_PASS || "";

const SHUTDOWN_TIMEOUT_SEC = parseInt(process.env.SHUTDOWN_TIMEOUT_SEC || "60", 10);
const TELEMETRY_INTERVAL_SEC = parseInt(process.env.TELEMETRY_INTERVAL_SEC || "0", 10);
const UPDATE_CHECK_INTERVAL_SEC = parseInt(process.env.UPDATE_CHECK_INTERVAL_SEC || "3600", 10);

const CATALOG = path.join(COBALT_DIR, "versions.json");
const PIN_FILE = path.join(COBALT_DIR, "pin");
const PENDING_ROLLBACK = path.join(COBALT_DIR, "pending_rollback");
const LAST_INSTALL = path.join(COBALT_DIR, "last_install");
const FRAMEWORKS_DIR = path.join(COBALT_DIR, "frameworks");
const CATALOG_MAX = 20;

// ---------- colors (panel renders ANSI; NO_COLOR to disable) ----------
const COLOR = !("NO_COLOR" in process.env);
const C = COLOR
  ? { reset: "\x1b[0m", dim: "\x1b[2m", red: "\x1b[31m", green: "\x1b[32m",
      yellow: "\x1b[33m", cyan: "\x1b[36m", magenta: "\x1b[35m", white: "\x1b[37m", rcon: "\x1b[36m" }
  : { reset: "", dim: "", red: "", green: "", yellow: "", cyan: "", magenta: "", white: "", rcon: "" };

// Optional custom palette. CONSOLE_COLORS = comma-separated hex in slot order
// normal,error,warn,oxide,carbon,rcon — OR name=hex pairs (e.g. oxide=cc66ff).
// Blank slots keep their default. Emitted as 24-bit truecolor ANSI, which the
// panel's xterm.js renders.
if (COLOR && (process.env.CONSOLE_COLORS || "").trim()) {
  const POS = ["green", "red", "yellow", "magenta", "cyan", "rcon"];
  const NAME = { normal: "green", error: "red", warn: "yellow", warning: "yellow",
                 oxide: "magenta", carbon: "cyan", rcon: "rcon" };
  const hexToAnsi = (h) => {
    const m = /^#?([0-9a-fA-F]{6})$/.exec((h || "").trim());
    if (!m) return null;
    const n = parseInt(m[1], 16);
    return `\x1b[38;2;${(n >> 16) & 255};${(n >> 8) & 255};${n & 255}m`;
  };
  const toks = process.env.CONSOLE_COLORS.split(",");
  const named = toks.some((t) => t.includes("="));
  toks.forEach((tok, i) => {
    tok = tok.trim();
    if (!tok) return;
    let key, hex;
    if (named) {
      const eq = tok.indexOf("=");
      if (eq < 0) return;
      key = NAME[tok.slice(0, eq).trim().toLowerCase()];
      hex = tok.slice(eq + 1);
    } else { key = POS[i]; hex = tok; }
    const ansi = key ? hexToAnsi(hex) : null;
    if (ansi) C[key] = ansi;
  });
}

// ---------- output ----------
const hhmm = () => {
  const d = new Date(), p = (n) => String(n).padStart(2, "0");
  return `${p(d.getHours())}:${p(d.getMinutes())}`;
};

fs.mkdirSync(COBALT_DIR, { recursive: true });
fs.mkdirSync(FRAMEWORKS_DIR, { recursive: true });
try { // rotate cobalt.log if large
  if (fs.existsSync(COBALT_LOG) && fs.statSync(COBALT_LOG).size > 5 * 1024 * 1024)
    fs.renameSync(COBALT_LOG, `${COBALT_LOG}.prev`);
} catch {}
const cobaltLog = fs.createWriteStream(COBALT_LOG, { flags: "a" });

// wrapper's own events: stdout + cobalt.log
function wline(msg, color) {
  process.stdout.write(`${C.dim}${hhmm()}${C.reset} ${color || ""}${msg}${color ? C.reset : ""}\n`);
  cobaltLog.write(`${hhmm()} ${msg.replace(/\x1b\[[0-9;]*m/g, "")}\n`);
}
const werr = (msg) => wline(msg, C.red);

// game/log lines: stdout only (they already live in unity.log)
// Colour scheme (v1: oxide=magenta, carbon=cyan, errors=red, normal=green) plus
// semantic highlights. Forced on unless NO_COLOR — v1 gated on isTTY, which is
// false under Wings' pipe, so v1 showed NO colour in the panel; v2 always does.
function colorForLine(t, isErr) {
  if (isErr) return C.red;
  if (/\b(error|exception|failed|failure|fatal|traceback|denied|refused)\b/.test(t)) return C.red;
  if (/\b(warn|warning|deprecat)/.test(t)) return C.yellow;
  if (/\bsav(e|ed|ing)\b|writing save|\bbackup\b/.test(t)) return C.yellow;
  if (/joined|connected|has entered|approved|authenticated/.test(t)) return C.green;
  if (/disconnect|has left|kicked|banned|timed out/.test(t)) return C.yellow;
  return C.green;
}
function gline(ln, isErr) {
  const t = ln.toLowerCase();
  const tag = t.includes("oxide") || t.includes("umod") ? "[oxide]"
    : t.includes("carbon") ? "[carbon]" : "";
  const color = tag === "[oxide]" ? C.magenta : tag === "[carbon]" ? C.cyan
    : colorForLine(t, isErr);
  process.stdout.write(`${C.dim}${hhmm()}${C.reset} ${color}${tag ? tag + " " : ""}${ln}${C.reset}\n`);
}

// ---------- helpers ----------
const readText = (f) => { try { return fs.readFileSync(f, "utf8").trim(); } catch { return null; } };
const readJson = (f) => { try { return JSON.parse(fs.readFileSync(f, "utf8")); } catch { return null; } };
const writeJson = (f, o) => fs.writeFileSync(f, JSON.stringify(o, null, 2));

function acfInfo() {
  const txt = readText(ACF);
  if (!txt) return null;
  const b = txt.match(/"buildid"\s+"(\d+)"/);
  const depots = [];
  const re = /"(\d+)"\s*\{\s*"manifest"\s+"(\d+)"/g;
  let m;
  while ((m = re.exec(txt))) depots.push({ id: m[1], manifest: m[2] });
  return { buildid: b ? parseInt(b[1], 10) : 0, depots };
}

function steamcmdCmd() {
  const p = process.env.COBALT_STEAMCMD ||
    [path.join(HOME, "steamcmd", "steamcmd.sh"), "/usr/games/steamcmd", "/usr/bin/steamcmd"].find((f) => fs.existsSync(f));
  if (!p) return null;
  // .js steamcmd = test fake, run through node
  return p.endsWith(".js") ? { cmd: process.execPath, pre: [p] } : { cmd: p, pre: [] };
}

function resolveRustPid() {
  try {
    for (const name of fs.readdirSync("/proc")) {
      if (!/^\d+$/.test(name)) continue;
      try {
        if (fs.readFileSync(`/proc/${name}/comm`, "utf8").trim() === "RustDedicated")
          return parseInt(name, 10);
      } catch {}
    }
  } catch {}
  return null;
}

// ---------- argv (single format: --argv <exe> <args...>) ----------
const looksLikeFlag = (s) => typeof s === "string" && /^[-+][A-Za-z0-9_.+-]+$/.test(s);
const SWITCH_ONLY = new Set(["-batchmode", "-nographics", "-nolog", "-no-gui"]);

// Pterodactyl splits quoted values into separate argv tokens; re-join them.
function repairSplitArgs(params) {
  const out = [];
  for (let i = 0; i < params.length;) {
    const tok = String(params[i]);
    if (looksLikeFlag(tok)) {
      out.push(tok); i++;
      if (SWITCH_ONLY.has(tok)) continue;
      if (i < params.length) {
        let val = String(params[i++]);
        while (i < params.length && !looksLikeFlag(params[i])) val += " " + String(params[i++]);
        out.push(val);
      }
    } else { out.push(tok); i++; }
  }
  return out;
}

const rawArgv = process.argv.slice(2);
const flagIdx = rawArgv.indexOf("--argv");
if (flagIdx === -1 || !rawArgv[flagIdx + 1]) {
  console.error(`${hhmm()} ERROR: usage: wrapper.js --argv <RustDedicated> <args...>`);
  process.exit(1);
}
const fullArgv = rawArgv.slice(flagIdx + 1).map(String);
const executable = fullArgv[0];
let params = repairSplitArgs(fullArgv.slice(1));

// inject -logfile if missing — the logfile is our read channel
if (!params.includes("-logfile")) {
  params.push("-logfile", UNITY_LOG);
}
const unityLogfile = params[params.indexOf("-logfile") + 1] || UNITY_LOG;

// ---------- log rotation (unity.log grows unbounded across week-long runs) ----------
try { if (fs.existsSync(unityLogfile)) fs.renameSync(unityLogfile, `${unityLogfile}.prev`); } catch {}
try { fs.closeSync(fs.openSync(unityLogfile, "a")); } catch {}

// ---------- catalog record (runs every boot; entrypoint wrote last_install) ----------
function recordCatalog() {
  const acf = acfInfo();
  if (!acf || !acf.buildid) return null;
  const li = readJson(LAST_INSTALL) || {};
  let cat = readJson(CATALOG);
  if (!Array.isArray(cat)) cat = [];
  const entry = {
    buildid: acf.buildid,
    depots: acf.depots,
    framework: li.framework || "unknown",
    frameworkVersion: li.version || "unknown",
    frameworkArtifact: li.artifact || "",
    recorded_at: new Date().toISOString(),
  };
  cat = [entry, ...cat.filter((e) => e.buildid !== acf.buildid)].slice(0, CATALOG_MAX);
  try { writeJson(CATALOG, cat); } catch (e) { werr(`[cobalt] catalog write failed: ${e.message}`); }
  // prune framework artifacts no catalog entry references
  try {
    const referenced = new Set(cat.map((e) => path.basename(e.frameworkArtifact || "")).filter(Boolean));
    for (const f of fs.readdirSync(FRAMEWORKS_DIR))
      if (!referenced.has(f)) fs.rmSync(path.join(FRAMEWORKS_DIR, f), { force: true });
  } catch {}
  return entry;
}
const bootEntry = recordCatalog();

// ---------- spawn game (plain pipes; no PTY — stdout is near-silent with -logfile) ----------
process.stdout.write(
  `${C.dim}${hhmm()}${C.reset} Executing: ${executable} ` +
  params.map((a) => (/[^A-Za-z0-9_/.:+-]/.test(a) ? `"${a.replace(/"/g, '\\"')}"` : a)).join(" ") + "\n",
);
if (bootEntry)
  wline(`[cobalt] build ${bootEntry.buildid} · ${bootEntry.framework} ${bootEntry.frameworkVersion}` +
    (readText(PIN_FILE) ? " · PINNED" : ""), readText(PIN_FILE) ? C.yellow : undefined);

// Carbon doorstop: the entrypoint hands us the paths as COBALT_ vars; apply the
// real DOORSTOP_*/LD_PRELOAD names to the GAME child only (never to node itself).
const childEnv = { ...process.env };
if (process.env.COBALT_DOORSTOP_TARGET) {
  childEnv.DOORSTOP_ENABLED = "1";
  childEnv.DOORSTOP_TARGET_ASSEMBLY = process.env.COBALT_DOORSTOP_TARGET;
  childEnv.LD_PRELOAD = process.env.COBALT_DOORSTOP_PRELOAD || "";
  childEnv.LD_LIBRARY_PATH = (process.env.COBALT_DOORSTOP_LDPATH || "") +
    (process.env.LD_LIBRARY_PATH ? ":" + process.env.LD_LIBRARY_PATH : "");
  childEnv.TERM = childEnv.TERM || "xterm";
  wline(`[cobalt] Carbon doorstop active for RustDedicated (${process.env.COBALT_DOORSTOP_PRELOAD})`);
}

const game = spawn(executable, params, { stdio: ["pipe", "pipe", "pipe"], cwd: HOME, shell: false, env: childEnv });

// native-crash output etc. still arrives on the pipes; show it tagged
const procBufs = { out: "", err: "" };
function onProcData(chunk, isErr) {
  const key = isErr ? "err" : "out";
  const lines = (procBufs[key] + chunk.toString()).split(/\r?\n/);
  procBufs[key] = lines.pop();
  for (const ln of lines) if (ln.trim()) gline(`[proc] ${ln}`, isErr);
}
game.stdout.on("data", (d) => onProcData(d, false));
game.stderr.on("data", (d) => onProcData(d, true));

// ---------- tail the unity logfile (the console) ----------
const tailProc = spawn("tail", ["-n", "+1", "-F", unityLogfile], { stdio: ["ignore", "pipe", "pipe"] });
let tailBuf = "";
tailProc.stdout.on("data", (d) => {
  const lines = (tailBuf + d.toString()).split(/\r?\n/);
  tailBuf = lines.pop();
  for (const ln of lines) if (ln.length) gline(ln, false);
});
tailProc.stderr.on("data", () => {}); // "file truncated" notices etc.
tailProc.on("error", (e) => werr(`[cobalt] tail failed: ${e.message} — console read channel dead`));

// ---------- WebRCON (persistent, matched-response-only, auto-reconnecting) ----------
let ws = null, wsReady = false, connecting = false, nextId = 1;
let announcedWaiting = false, exiting = false;
const pendingResp = new Map(); // id -> { cmd, ts }
const sendQueue = [];          // commands queued before rcon is up
const QUEUE_MAX = 20;

// Rust boots with RCON DOWN, so the first attempts always fail. A steady 3s
// retry + these guards drive reconnection — we must NOT depend on which of
// error/close undici fires (on Linux a refused connect fires error WITHOUT
// close), or the loop dies after one failed attempt and never reconnects.
function rconConnect() {
  if (!RCON_PASS || exiting || connecting || wsReady) return;
  connecting = true;
  let sock;
  try { sock = new WebSocket(`ws://${RCON_HOST}:${RCON_PORT}/${encodeURIComponent(RCON_PASS)}`); }
  catch (e) { connecting = false; werr(`[rcon] connect error: ${e.message}`); return; }
  ws = sock;
  let settled = false;
  const timer = setTimeout(() => done("connect timeout"), 10000);
  function done(why) {                 // fires on error OR close OR timeout, once
    if (settled) return; settled = true;
    clearTimeout(timer); connecting = false;
    const wasReady = wsReady; wsReady = false;
    if (ws === sock) ws = null;
    try { sock.close(); } catch {}
    if (wasReady) wline(`[rcon] disconnected (${why}) — retrying`);
  }
  sock.addEventListener("open", () => {
    settled = true; clearTimeout(timer); connecting = false; wsReady = true; announcedWaiting = false;
    wline(`[rcon] connected (${RCON_HOST}:${RCON_PORT})`);
    while (sendQueue.length && wsReady) rconSend(sendQueue.shift());
  });
  sock.addEventListener("message", (ev) => {
    if (typeof ev.data !== "string") return;
    let obj; try { obj = JSON.parse(ev.data); } catch { return; }
    // Rust WebRCON broadcasts everything; only print replies to OUR commands.
    if (!pendingResp.has(obj.Identifier)) return;
    pendingResp.delete(obj.Identifier);
    const body = String(obj.Message ?? "").replace(/[\x00-\x08\x0B-\x1F\x7F]/g, "");
    for (const ln of body.split(/\r?\n/)) {
      if (!ln.trim()) continue;
      process.stdout.write(`${C.dim}${hhmm()}${C.reset} ${C.rcon}[rcon] ${ln}${C.reset}\n`);
    }
  });
  sock.addEventListener("error", () => done("error"));
  sock.addEventListener("close", (e) => done("close " + ((e && e.code) || "")));
}

function rconSend(cmd) {
  if (!RCON_PASS) { werr("[rcon] disabled — RCON_PASS not set"); return false; }
  if (!wsReady || !ws) {
    if (sendQueue.length < QUEUE_MAX) {
      sendQueue.push(cmd);
      if (!announcedWaiting) { wline("[rcon] not connected yet — command queued"); announcedWaiting = true; }
    } else werr("[rcon] queue full — command dropped");
    return false;
  }
  const now = Date.now();
  for (const [id, e] of pendingResp) if (now - e.ts > 30000) pendingResp.delete(id);
  const id = nextId++;
  pendingResp.set(id, { cmd, ts: now });
  try { ws.send(JSON.stringify({ Identifier: id, Message: cmd, Name: "Cobalt" })); return true; }
  catch (e) { pendingResp.delete(id); werr(`[rcon] send failed: ${e.message}`); return false; }
}

wline(`[rcon] connecting to ${RCON_HOST}:${RCON_PORT}…`);
rconConnect();
setInterval(rconConnect, 3000).unref(); // retry until connected; reconnect after any drop

// ---------- telemetry (the GAME's cpu/rss via /proc, not the wrapper's) ----------
let lastStat = null; // { pid, total, at }
function printTelemetry() {
  const pid = resolveRustPid();
  let cpuStr = "n/a", rssStr = "n/a";
  if (pid) {
    try {
      const stat = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
      const parts = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
      const total = (parseInt(parts[11], 10) + parseInt(parts[12], 10)) / 100; // utime+stime @ 100Hz
      const now = Date.now();
      if (lastStat && lastStat.pid === pid) {
        const pct = ((total - lastStat.total) / ((now - lastStat.at) / 1000)) * 100;
        cpuStr = `${pct.toFixed(1)}%`;
      } else cpuStr = "(sampling)";
      lastStat = { pid, total, at: now };
      const rss = /VmRSS:\s+(\d+) kB/.exec(fs.readFileSync(`/proc/${pid}/status`, "utf8"));
      if (rss) rssStr = `${(parseInt(rss[1], 10) / 1024).toFixed(0)}MB`;
    } catch {}
  }
  let disk = "n/a";
  try { const s = fs.statfsSync(HOME); disk = `${((s.bavail * s.bsize) / 1024 ** 3).toFixed(1)}GB free`; } catch {}
  const load = os.loadavg().map((v) => v.toFixed(2)).join(", ");
  wline(`[telemetry] game cpu=${cpuStr} rss=${rssStr} loadavg=${load} disk=${disk}` +
    (pid ? "" : " (RustDedicated pid not found)"));
}
if (TELEMETRY_INTERVAL_SEC > 0) setInterval(printTelemetry, TELEMETRY_INTERVAL_SEC * 1000).unref();

// ---------- update watcher (warn-only; 2.1 will automate) ----------
let warnedBuild = 0;
function checkForUpdate() {
  const sc = steamcmdCmd();
  const acf = acfInfo();
  if (!sc || !acf || !acf.buildid || exiting) return;
  const p = spawn(sc.cmd, [...sc.pre, "+login", "anonymous", "+app_info_update", "1", "+app_info_print", APPID, "+quit"],
    { stdio: ["ignore", "pipe", "ignore"] });
  let out = "";
  p.stdout.on("data", (d) => (out += d));
  p.on("exit", () => {
    const m = /"public"\s*\{\s*"buildid"\s+"(\d+)"/.exec(out);
    if (!m) return;
    const remote = parseInt(m[1], 10);
    if (remote > acf.buildid && remote !== warnedBuild) {
      warnedBuild = remote;
      const pinned = readText(PIN_FILE);
      werr(`[update] Rust build ${remote} is out (installed: ${acf.buildid}).` +
        (pinned ? ` Server is PINNED to ${pinned} — .unpin + restart to update.` : " Restart to update."));
    }
  });
  p.on("error", () => {});
}
if (UPDATE_CHECK_INTERVAL_SEC > 0) {
  setTimeout(checkForUpdate, 5 * 60 * 1000).unref(); // first check 5 min after boot
  setInterval(checkForUpdate, UPDATE_CHECK_INTERVAL_SEC * 1000).unref();
}

// ---------- panel commands ----------
function cmdHelp() {
  wline("[cobalt] commands: !<sh> · .version · .pin [build] · .unpin · .rollback <build|last> · " +
    ".telemetry · rcon:<x> · quit");
}

function cmdVersion() {
  const acf = acfInfo();
  const pin = readText(PIN_FILE);
  const li = readJson(LAST_INSTALL) || {};
  wline(`[version] installed build: ${acf ? acf.buildid : "unknown"} · framework: ${li.framework || "?"} ${li.version || ""}` +
    (pin ? ` · pinned: ${pin}` : " · not pinned"));
  if (fs.existsSync(PENDING_ROLLBACK)) wline("[version] rollback staged — restart to apply", C.yellow);
  const cat = readJson(CATALOG) || [];
  if (!cat.length) return wline("[version] catalog empty (populates after first update)");
  wline("[version] catalog (newest first):");
  for (const e of cat) {
    const art = e.frameworkArtifact && fs.existsSync(e.frameworkArtifact) ? "archived" : "-";
    wline(`  ${e.buildid}  ${e.framework} ${e.frameworkVersion}  fw:${art}  ${(e.recorded_at || "").slice(0, 10)}`);
  }
}

function cmdPin(arg) {
  const acf = acfInfo();
  const build = arg ? parseInt(arg, 10) : acf ? acf.buildid : 0;
  if (!build) return werr("[pin] no buildid (no acf yet?) — usage: .pin [buildid]");
  fs.writeFileSync(PIN_FILE, String(build));
  wline(`[pin] pinned to build ${build} — updates skipped until .unpin. ` +
    "NOTE: clients force-update; a pinned server goes protocol-incompatible within days.", C.yellow);
}

function cmdUnpin() {
  fs.rmSync(PIN_FILE, { force: true });
  wline("[pin] unpinned — next boot resumes updates");
}

let rollbackActive = false;
function cmdRollback(arg) {
  if (rollbackActive) return werr("[rollback] already staging");
  const cat = readJson(CATALOG) || [];
  const acf = acfInfo();
  if (!cat.length) return werr("[rollback] catalog empty — nothing recorded to roll back to");
  let target = null;
  if (arg === "last") target = cat.find((e) => !acf || e.buildid !== acf.buildid) || null;
  else target = cat.find((e) => e.buildid === parseInt(arg, 10)) || null;
  if (!target) return werr(`[rollback] no catalog entry for '${arg}' — see .version`);
  if (!target.depots || !target.depots.length) return werr("[rollback] entry has no depot manifests recorded");
  // disk headroom: download_depot writes a full extra copy
  try {
    const s = fs.statfsSync(HOME);
    const freeGB = (s.bavail * s.bsize) / 1024 ** 3;
    if (freeGB < 10) return werr(`[rollback] need ~10GB free, have ${freeGB.toFixed(1)}GB — aborting`);
  } catch {}
  const ageDays = (Date.now() - Date.parse(target.recorded_at || 0)) / 86400000;
  if (ageDays > 90) wline(`[rollback] entry is ${ageDays.toFixed(0)} days old — Steam may no longer serve its manifests`, C.yellow);
  const sc = steamcmdCmd();
  if (!sc) return werr("[rollback] steamcmd not found");

  rollbackActive = true;
  wline(`[rollback] staging build ${target.buildid} (${target.depots.length} depot(s)) — server keeps running`);
  const depots = [...target.depots];
  const next = () => {
    const d = depots.shift();
    if (!d) {
      writeJson(PENDING_ROLLBACK, target);
      fs.writeFileSync(PIN_FILE, String(target.buildid));
      rollbackActive = false;
      wline(`[rollback] staged + pinned to ${target.buildid}. RESTART the server to apply.`, C.green);
      return;
    }
    wline(`[rollback] downloading depot ${d.id} manifest ${d.manifest}…`);
    const p = spawn(sc.cmd, [...sc.pre, "+login", "anonymous", "+download_depot", APPID, d.id, d.manifest, "+quit"],
      { stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    const onD = (buf) => {
      out += buf.toString();
      for (const ln of buf.toString().split(/\r?\n/))
        if (ln.trim() && /Depot download complete|error|failed|denied/i.test(ln)) wline(`[rollback] ${ln.trim()}`);
    };
    p.stdout.on("data", onD); p.stderr.on("data", onD);
    p.on("exit", (code) => {
      if (code !== 0 || !/Depot download complete/i.test(out)) {
        rollbackActive = false;
        return werr(`[rollback] depot ${d.id} download FAILED (exit ${code}) — rollback NOT staged. ` +
          "Old manifests may no longer be served by Steam.");
      }
      next();
    });
    p.on("error", (e) => { rollbackActive = false; werr(`[rollback] steamcmd spawn failed: ${e.message}`); });
  };
  next();
}

// ---------- graceful stop ----------
let stopping = false;
function gracefulStop(reason) {
  if (stopping) return;
  stopping = true;
  wline(`[cobalt] stopping (${reason}) — quit via ${wsReady ? "rcon" : "stdin"}, waiting up to ${SHUTDOWN_TIMEOUT_SEC}s for save`);
  let delivered = false;
  if (wsReady && ws) {
    try { ws.send(JSON.stringify({ Identifier: nextId++, Message: "quit", Name: "Cobalt" })); delivered = true; } catch {}
  }
  if (!delivered) { try { game.stdin.write("quit\n"); } catch {} }
  setTimeout(() => {
    if (game.exitCode === null) {
      werr(`[cobalt] no exit after ${SHUTDOWN_TIMEOUT_SEC}s — SIGTERM`);
      try { game.kill("SIGTERM"); } catch {}
      setTimeout(() => {
        if (game.exitCode === null) { werr("[cobalt] SIGKILL"); try { game.kill("SIGKILL"); } catch {} }
      }, 10000).unref();
    }
  }, SHUTDOWN_TIMEOUT_SEC * 1000).unref();
}
["SIGTERM", "SIGINT"].forEach((sig) => process.on(sig, () => gracefulStop(sig)));

// ---------- panel input router ----------
process.stdin.setEncoding("utf8");
let stdinBuf = "";
process.stdin.on("data", (txt) => {
  stdinBuf += txt;
  const lines = stdinBuf.split(/\r?\n/);
  stdinBuf = lines.pop();
  for (const raw of lines) {
    const line = raw.trim();
    if (!line) continue;

    if (/^quit$/i.test(line)) { gracefulStop("stop command"); continue; }

    if (line.startsWith("!")) {
      const sh = line.slice(1).trim();
      if (!sh) { werr("[shell] empty"); continue; }
      wline(`[shell] ${sh}`);
      const p = spawn("bash", ["-lc", sh], { stdio: ["ignore", "pipe", "pipe"], cwd: HOME });
      p.stdout.on("data", (d) => process.stdout.write(d));
      p.stderr.on("data", (d) => process.stderr.write(d));
      p.on("exit", (code) => wline(`[shell] exit ${code}`));
      p.on("error", (e) => werr(`[shell] ${e.message}`));
      continue;
    }

    const lower = line.toLowerCase();
    if (lower === ".help") { cmdHelp(); continue; }
    if (lower === ".version") { cmdVersion(); continue; }
    if (lower === ".telemetry") { printTelemetry(); continue; }
    if (lower === ".unpin") { cmdUnpin(); continue; }
    if (lower === ".pin" || lower.startsWith(".pin ")) { cmdPin(line.slice(4).trim()); continue; }
    if (lower.startsWith(".rollback")) {
      const arg = line.slice(9).trim();
      if (!arg) { werr("[rollback] usage: .rollback <buildid|last>"); continue; }
      cmdRollback(arg); continue;
    }
    if (lower.startsWith("rcon:")) { rconSend(line.slice(5).trim()); continue; }
    if (line.startsWith(".")) { werr(`[cobalt] unknown command '${line}' — .help`); continue; }

    rconSend(line); // default route
  }
});
process.stdin.resume();

// ---------- game exit ----------
game.on("error", (e) => { werr(`[cobalt] failed to start game: ${e.message}`); process.exit(1); });
game.on("exit", (code, signal) => {
  exiting = true;
  try { if (ws) ws.close(); } catch {}
  wline(`[cobalt] server exited with code ${code}${signal ? ` (signal ${signal})` : ""}`);
  // give tail a beat to flush the last log lines, then stop it and exit
  setTimeout(() => {
    try { tailProc.kill("SIGTERM"); } catch {}
    if (tailBuf.trim()) gline(tailBuf, false);
    cobaltLog.end();
    process.exit(code ?? 0);
  }, 250);
});
