#!/usr/bin/env node

// ============================================================================
// Rust wrapper — argv-safe + logfile mirroring (minimal pretty console)
// - Args via --argv-file (NUL/newline), --argv-json, --argv-b64, or legacy --argv
// - Repairs split multi-word values (-flags and +commands)
// - Console output: "hh:mm <message>", plus [oxide]/[carbon] tag when detected
// - RAW output mirrored to latest.log (no timestamps / no tags)
// - If -logfile is present, tails it and mirrors as well
// ============================================================================

const { spawn } = require("child_process");
const fs = require("fs");

// ---------- config ----------
const LATEST_LOG = process.env.LATEST_LOG || "/home/container/latest.log";
const COLOR_OK = process.stdout.isTTY && !("NO_COLOR" in process.env);

// ---------- colors (soft; auto-disabled) ----------
const C = COLOR_OK
  ? {
      reset: "\x1b[0m",
      dim: "\x1b[2m",
      fg: {
        red: "\x1b[31m",
        green: "\x1b[32m",
        yellow: "\x1b[33m",
        cyan: "\x1b[36m",
        magenta: "\x1b[35m",
        white: "\x1b[37m",
      },
    }
  : { reset: "", dim: "", fg: { red: "", green: "", yellow: "", cyan: "", magenta: "", white: "" } };

// ---------- tiny helpers ----------
const hhmm = () => {
  const d = new Date();
  const pad = (n) => String(n).padStart(2, "0");
  return `${pad(d.getHours())}:${pad(d.getMinutes())}`;
};
const looksLikeFlag = (s) => typeof s === "string" && /^[-+][A-Za-z0-9_.-]+$/.test(s);

// flags that consume no value
const SWITCH_ONLY = new Set(["-batchmode", "-nographics", "-nolog", "-no-gui"]);

// join split values until next token looks like a flag
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
        while (i < params.length && !looksLikeFlag(params[i])) val += " " + String(params[i++]);
        out.push(val);
      }
    } else {
      out.push(tok);
      i++;
    }
  }
  return out;
}

// classify a line to tag [oxide] or [carbon] when obvious
function tagForLine(s) {
  const t = s.toLowerCase();
  if (t.includes("oxide") || t.includes("umod")) return "[oxide]";
  if (t.includes("carbon")) return "[carbon]";
  return "";
}

// ---------- log file setup (RAW mirroring) ----------
try { if (fs.existsSync(LATEST_LOG)) fs.renameSync(LATEST_LOG, `${LATEST_LOG}.prev`); } catch {}
try { fs.writeFileSync(LATEST_LOG, "", { flag: "w" }); } catch {}

// ---------- argv decode ----------
const argv = process.argv.slice(2);

function decodeArgv() {
  let i = argv.indexOf("--argv-json");
  if (i !== -1 && argv[i + 1]) {
    try {
      const arr = JSON.parse(argv[i + 1]);
      if (!Array.isArray(arr) || arr.length === 0) throw new Error();
      return arr.map(String);
    } catch {
      console.error(`${hhmm()} ERROR: --argv-json must be a JSON array of strings.`);
      process.exit(1);
    }
  }

  i = argv.indexOf("--argv-b64");
  if (i !== -1 && argv[i + 1]) {
    try {
      const json = Buffer.from(argv[i + 1], "base64").toString("utf8");
      const arr = JSON.parse(json);
      if (!Array.isArray(arr) || arr.length === 0) throw new Error();
      return arr.map(String);
    } catch {
      console.error(`${hhmm()} ERROR: --argv-b64 must be base64 of a JSON array of strings.`);
      process.exit(1);
    }
  }

  i = argv.indexOf("--argv-file");
  if (i !== -1 && argv[i + 1]) {
    try {
      const buf = fs.readFileSync(argv[i + 1]);
      let parts = buf.toString("utf8").split("\0").filter((s) => s.length > 0);
      if (parts.length <= 1) parts = buf.toString("utf8").split(/\r?\n/).filter((s) => s.length > 0);
      if (parts.length === 0) throw new Error("empty argv file");
      return parts.map(String);
    } catch (e) {
      console.error(`${hhmm()} ERROR: --argv-file must be readable: ${e.message || e}`);
      process.exit(1);
    }
  }

  if (process.env.RUST_ARGS_JSON) {
    try {
      const arr = JSON.parse(process.env.RUST_ARGS_JSON);
      if (!Array.isArray(arr) || arr.length === 0) throw new Error();
      return arr.map(String);
    } catch {
      console.error(`${hhmm()} ERROR: RUST_ARGS_JSON must be a JSON array of strings.`);
      process.exit(1);
    }
  }

  const flagIndex = argv.indexOf("--argv");
  if (flagIndex === -1) {
    console.error(`${hhmm()} ERROR: Missing argv source. Use --argv-file/--argv-json/--argv-b64 or legacy --argv.`);
    process.exit(1);
  }
  const legacy = argv.slice(flagIndex + 1);
  if (legacy.length === 0) {
    console.error(`${hhmm()} ERROR: No arguments provided for RustDedicated.`);
    process.exit(1);
  }
  return legacy.map(String);
}

const fullArgv = decodeArgv();
const executable = fullArgv[0];
let params = fullArgv.slice(1);
params = repairSplitArgs(params);

if (!executable) {
  console.error(`${hhmm()} ERROR: First argv element must be the RustDedicated binary.`);
  process.exit(1);
}

// minimal pretty “Executing …” line
process.stdout.write(`${C.dim}${hhmm()}${C.reset} Executing: ${executable} ` +
  params.map((a) => (/[^A-Za-z0-9_/.:-]/.test(a) ? `"${a}"` : a)).join(" ") + "\n");

// detect -logfile for mirroring
let unityLogfile = null;
for (let i = 0; i < params.length; i++) {
  if (params[i] === "-logfile" && i + 1 < params.length) { unityLogfile = params[i + 1]; break; }
}

// ---------- pretty mirroring ----------
const buffers = Object.create(null); // source -> partial line

function emitPretty(sourceKey, chunk, isErr = false) {
  const key = sourceKey + (isErr ? ":err" : ":out");
  const prev = buffers[key] || "";
  const raw = chunk.toString();

  // RAW to latest.log (no timestamps/tags)
  try { fs.appendFile(LATEST_LOG, raw.replace(/\r/g, ""), () => {}); } catch {}

  const s = prev + raw;
  const lines = s.split(/\r?\n/);
  buffers[key] = lines.pop(); // keep trailing partial

  for (const ln of lines) {
    const label = tagForLine(ln); // "", "[oxide]", or "[carbon]"
    const color =
      label === "[oxide]" ? C.fg.magenta :
      label === "[carbon]" ? C.fg.cyan :
      isErr ? C.fg.red : C.fg.green;

    // hh:mm + optional tag, no [game]/[wrapper]
    const out = `${C.dim}${hhmm()}${C.reset} ${label ? label + " " : ""}${ln}`;
    (isErr ? process.stderr : process.stdout).write(`${color}${out}${C.reset}\n`);
  }
}

const game = spawn(executable, params, { stdio: ["pipe", "pipe", "pipe"], cwd: "/home/container" });

game.stdout.on("data", (d) => emitPretty("game", d, false));
game.stderr.on("data", (d) => emitPretty("game", d, true));

// tail the unity -logfile if provided
let tailProc = null;
if (unityLogfile) {
  try { fs.closeSync(fs.openSync(unityLogfile, "a")); } catch {}
  process.stdout.write(`${C.dim}${hhmm()}${C.reset} Mirroring logfile: ${unityLogfile}\n`);
  tailProc = spawn("tail", ["-n", "+1", "-F", unityLogfile], { stdio: ["ignore", "pipe", "pipe"] });
  const tailMirror = (d) => emitPretty("unity", d, false);
  tailProc.stdout.on("data", tailMirror);
  tailProc.stderr.on("data", tailMirror);
}

process.stdin.setEncoding("utf8");
process.stdin.on("data", (txt) => { try { game.stdin.write(txt); } catch {} });
process.stdin.resume();

let exited = false;
["SIGTERM", "SIGINT"].forEach((sig) => {
  process.on(sig, () => {
    if (!exited) {
      const line = `${C.dim}${hhmm()}${C.reset} stopping server...`;
      process.stdout.write(`${line}\n`);
      try { game.stdin.write("quit\n"); } catch {}
      setTimeout(() => { try { game.kill("TERM"); } catch {} }, 5000);
    }
  });
});

game.on("exit", (code) => {
  exited = true;
  if (tailProc && !tailProc.killed) { try { tailProc.kill("TERM"); } catch {} }

  // flush any trailing partial lines for visual completeness
  for (const k of Object.keys(buffers)) {
    const rem = buffers[k]; if (!rem) continue;
    const label = tagForLine(rem);
    const color = label === "[oxide]" ? C.fg.magenta : label === "[carbon]" ? C.fg.cyan : C.fg.white;
    const out = `${C.dim}${hhmm()}${C.reset} ${label ? label + " " : ""}${rem}`;
    process.stdout.write(`${color}${out}${C.reset}\n`);
    buffers[k] = "";
  }

  const summary = `${C.dim}${hhmm()}${C.reset} exited with code: ${code}`;
  process.stdout.write(`${summary}\n`);
  process.exit(code ?? 0);
});
