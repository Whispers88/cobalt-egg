#!/usr/bin/env node

// ============================================================================
// Rust wrapper — Console-first (NO RCON), argv-safe + logfile mirroring
// - Accepts argv via --argv-file (NUL/newline), --argv-json, --argv-b64,
//   or legacy --argv <args...>
// - Repairs split multi-word values (-flags and +commands)
// - Pretty console: timestamps, source tags, soft colors (auto-disables if not TTY)
// - Writes RAW server output to latest.log (no timestamps/colors)
// - If -logfile is present, tails and mirrors it as well
// ============================================================================

const { spawn } = require("child_process");
const fs = require("fs");

// ----------------------- config -----------------------
const LATEST_LOG = process.env.LATEST_LOG || "/home/container/latest.log";
const PRETTY = (process.env.WRAPPER_PRETTY || "1") !== "0";  // set 0 to disable
const TIME_FMT = process.env.WRAPPER_TS_FMT || "iso";        // "iso" or "hmss"
const COLOR_OK = PRETTY && process.stdout.isTTY && !("NO_COLOR" in process.env);

// ----------------------- colors -----------------------
const C = COLOR_OK
  ? {
      reset: "\x1b[0m",
      dim: "\x1b[2m",
      bold: "\x1b[1m",
      fg: {
        gray: "\x1b[90m",
        red: "\x1b[31m",
        green: "\x1b[32m",
        yellow: "\x1b[33m",
        blue: "\x1b[34m",
        magenta: "\x1b[35m",
        cyan: "\x1b[36m",
        white: "\x1b[37m",
      },
    }
  : {
      reset: "",
      dim: "",
      bold: "",
      fg: { gray: "", red: "", green: "", yellow: "", blue: "", magenta: "", cyan: "", white: "" },
    };

// ----------------------- time/format helpers -----------------------
function ts() {
  if (TIME_FMT === "hmss") {
    const d = new Date();
    const pad = (n, l = 2) => String(n).padStart(l, "0");
    return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  }
  // ISO with seconds.millis, but shorter than full
  return new Date().toISOString().replace("T", " ").replace("Z", "");
}
function tag(label, color) {
  return `${C.dim}[${color}${label}${C.reset}${C.dim}]${C.reset}`;
}
function linePrefix(label, color) {
  return `${C.dim}${ts()}${C.reset} ${tag(label, color)}`;
}
function looksLikeFlag(s) {
  return typeof s === "string" && /^[-+][A-Za-z0-9_.-]+$/.test(s);
}

// Switch-only flags (consume no value)
const SWITCH_ONLY = new Set([
  "-batchmode",
  "-nographics",
  "-nolog",
  "-no-gui",
]);

// Repair split values in argv
function repairSplitArgs(params) {
  const out = [];
  for (let i = 0; i < params.length; ) {
    const tok = String(params[i]);
    if (looksLikeFlag(tok)) {
      out.push(tok);
      i++;
      if (SWITCH_ONLY.has(tok)) continue;
      if (i < params.length) {
        let val = String(params[i++]);
        while (i < params.length && !looksLikeFlag(params[i])) {
          val += " " + String(params[i++]);
        }
        out.push(val);
      }
    } else {
      out.push(tok);
      i++;
    }
  }
  return out;
}

// ----------------------- log setup -----------------------
function wlog(msg, level = "info") {
  const color = level === "error" ? C.fg.red : level === "warn" ? C.fg.yellow : C.fg.cyan;
  const pfx = linePrefix("wrapper", color);
  process.stdout.write(`${pfx} ${msg}\n`);
}
function werr(msg) {
  const pfx = linePrefix("wrapper", C.fg.red);
  process.stderr.write(`${pfx} ${msg}\n`);
}

// Rotate & open latest.log (RAW data only)
try {
  if (fs.existsSync(LATEST_LOG)) fs.renameSync(LATEST_LOG, `${LATEST_LOG}.prev`);
} catch {}
try {
  fs.writeFileSync(LATEST_LOG, "", { flag: "w" });
} catch (e) {
  werr(`ERROR: unable to open ${LATEST_LOG}: ${e.message}`);
}

// ----------------------- argv decode -----------------------
const argv = process.argv.slice(2);

function decodeArgv() {
  // --argv-json
  let i = argv.indexOf("--argv-json");
  if (i !== -1 && argv[i + 1]) {
    try {
      const arr = JSON.parse(argv[i + 1]);
      if (!Array.isArray(arr) || arr.length === 0) throw new Error();
      return arr.map(String);
    } catch {
      werr("ERROR: --argv-json must be a JSON array of strings.");
      process.exit(1);
    }
  }
  // --argv-b64
  i = argv.indexOf("--argv-b64");
  if (i !== -1 && argv[i + 1]) {
    try {
      const json = Buffer.from(argv[i + 1], "base64").toString("utf8");
      const arr = JSON.parse(json);
      if (!Array.isArray(arr) || arr.length === 0) throw new Error();
      return arr.map(String);
    } catch {
      werr("ERROR: --argv-b64 must be base64 of a JSON array of strings.");
      process.exit(1);
    }
  }
  // --argv-file
  i = argv.indexOf("--argv-file");
  if (i !== -1 && argv[i + 1]) {
    try {
      const buf = fs.readFileSync(argv[i + 1]);
      let parts = buf.toString("utf8").split("\0").filter((s) => s.length > 0);
      if (parts.length <= 1) {
        parts = buf.toString("utf8").split(/\r?\n/).filter((s) => s.length > 0);
      }
      if (parts.length === 0) throw new Error("empty argv file");
      return parts.map(String);
    } catch (e) {
      werr(`ERROR: --argv-file must be readable (NUL/newline-separated): ${e.message || e}`);
      process.exit(1);
    }
  }
  // env JSON
  if (process.env.RUST_ARGS_JSON) {
    try {
      const arr = JSON.parse(process.env.RUST_ARGS_JSON);
      if (!Array.isArray(arr) || arr.length === 0) throw new Error();
      return arr.map(String);
    } catch {
      werr("ERROR: RUST_ARGS_JSON must be a JSON array of strings.");
      process.exit(1);
    }
  }
  // legacy --argv
  const flagIndex = argv.indexOf("--argv");
  if (flagIndex === -1) {
    werr("ERROR: Missing argv source. Use --argv-file/--argv-json/--argv-b64, RUST_ARGS_JSON, or legacy --argv.");
    process.exit(1);
  }
  const legacy = argv.slice(flagIndex + 1);
  if (legacy.length === 0) {
    werr("ERROR: No arguments provided for RustDedicated.");
    process.exit(1);
  }
  return legacy.map(String);
}

const fullArgv = decodeArgv();
const executable = fullArgv[0];
let params = fullArgv.slice(1);
params = repairSplitArgs(params);

if (!executable) {
  werr("ERROR: First argv element must be the RustDedicated binary.");
  process.exit(1);
}

wlog(
  `Executing: ${C.bold}${executable}${C.reset} ` +
    params.map((a) => (/[^A-Za-z0-9_/.:-]/.test(a) ? `"${a}"` : a)).join(" ")
);

// Detect -logfile path (next token is the path)
let unityLogfile = null;
for (let i = 0; i < params.length; i++) {
  if (params[i] === "-logfile" && i + 1 < params.length) {
    unityLogfile = params[i + 1];
    break;
  }
}

// ----------------------- pretty mirroring -----------------------
const buffers = Object.create(null); // per-source line buffers

function emitPretty(source, color, chunk, isErr = false) {
  const key = source + (isErr ? ":err" : ":out");
  const prev = buffers[key] || "";
  const s = prev + chunk.toString();

  // Write RAW to latest.log (no prettification)
  try {
    fs.appendFile(LATEST_LOG, chunk.toString().replace(/\r/g, ""), () => {});
  } catch {}

  const lines = s.split(/\r?\n/);
  buffers[key] = lines.pop(); // keep trailing partial line

  const pfx = linePrefix(source, color);
  for (const ln of lines) {
    const outLine = `${pfx} ${ln}`;
    if (isErr) process.stderr.write(outLine + "\n");
    else process.stdout.write(outLine + "\n");
  }
}

const gameColorOut = C.fg.green;
const gameColorErr = C.fg.red;
const tailColor = C.fg.yellow;

// Spawn WITHOUT shell: exact argv preserved
const game = spawn(executable, params, {
  stdio: ["pipe", "pipe", "pipe"],
  cwd: "/home/container",
});

game.stdout.on("data", (d) => emitPretty("game", gameColorOut, d, false));
game.stderr.on("data", (d) => emitPretty("game", gameColorErr, d, true));

// If -logfile is set, tail it and mirror to the panel too
let tailProc = null;
if (unityLogfile) {
  try { fs.closeSync(fs.openSync(unityLogfile, "a")); } catch {}
  wlog(`Mirroring -logfile: ${unityLogfile}`);
  tailProc = spawn("tail", ["-n", "+1", "-F", unityLogfile], { stdio: ["ignore", "pipe", "pipe"] });
  const tailMirror = (d) => emitPretty("unity", tailColor, d, false);
  tailProc.stdout.on("data", tailMirror);
  tailProc.stderr.on("data", tailMirror);
  tailProc.on("exit", (c) => wlog(`tail exited (${c}).`));
}

// Forward panel input → server stdin
process.stdin.setEncoding("utf8");
process.stdin.on("data", (txt) => {
  try { game.stdin.write(txt); } catch {}
});
process.stdin.resume();

// Graceful shutdown
let exited = false;
["SIGTERM", "SIGINT"].forEach((sig) => {
  process.on(sig, () => {
    if (!exited) {
      wlog(`${sig} → stopping server...`);
      try { game.stdin.write("quit\n"); } catch {}
      setTimeout(() => { try { game.kill("TERM"); } catch {} }, 5000);
    }
  });
});

game.on("exit", (code) => {
  exited = true;
  if (tailProc && !tailProc.killed) { try { tailProc.kill("TERM"); } catch {} }
  wlog(`Rust exited with code: ${code}`, code ? "warn" : "info");

  // Flush any trailing partial lines so nothing is lost visually
  for (const k of Object.keys(buffers)) {
    const rem = buffers[k];
    if (!rem) continue;
    const [src, kind] = k.split(":");
    const color = src === "game" ? (kind === "err" ? gameColorErr : gameColorOut) : tailColor;
    const pfx = linePrefix(src, color);
    const outLine = `${pfx} ${rem}`;
    if (kind === "err") process.stderr.write(outLine + "\n");
    else process.stdout.write(outLine + "\n");
    buffers[k] = "";
  }

  process.exit(code ?? 0);
});
