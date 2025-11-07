#!/usr/bin/env node

// ============================================================================
// Rust wrapper -- Console-first (NO RCON), argv-safe + logfile mirroring
// - Accepts argv via --argv-file (NUL/newline), --argv-json, --argv-b64,
//   or legacy --argv <args...>
// - Repairs split multi-word values in JS (handles -flags and +commands)
// - Spawns RustDedicated WITHOUT a shell (preserves multi-word args)
// - Mirrors stdout/stderr to panel, writes raw to latest.log
// - If -logfile is present, tails it and mirrors to panel too
// ============================================================================

const { spawn } = require("child_process");
const fs = require("fs");

const LATEST_LOG = process.env.LATEST_LOG || "/home/container/latest.log";

// rotate previous log
try {
  if (fs.existsSync(LATEST_LOG)) fs.renameSync(LATEST_LOG, `${LATEST_LOG}.prev`);
} catch {}
try {
  fs.writeFileSync(LATEST_LOG, "", { flag: "w" });
} catch (e) {
  console.error(`[wrapper] ERROR: unable to open ${LATEST_LOG}: ${e.message}`);
}

// ----------------------- helpers -----------------------
const looksLikeFlag = (s) => typeof s === "string" && /^[-+][A-Za-z0-9_.-]+$/.test(s);

// Some switches take **no value**; keep them standalone.
const SWITCH_ONLY = new Set([
  "-batchmode",
  "-nographics",
  "-nolog",
  "-no-gui",
  // add more switch-only flags here if needed
]);

/**
 * Repair split values:
 * Turns ["+server.hostname","A","Rust","Server","+server.level","Procedural","Map"]
 * into ["+server.hostname","A Rust Server","+server.level","Procedural Map"]
 *
 * Works for both -flags and +commands. Leaves non-flag tokens as-is.
 */
function repairSplitArgs(params) {
  const out = [];
  for (let i = 0; i < params.length; ) {
    const tok = String(params[i]);
    if (looksLikeFlag(tok)) {
      // push the flag itself
      out.push(tok);
      i++;

      // switch-only? no value consumed
      if (SWITCH_ONLY.has(tok)) continue;

      // if there is at least one value, start with it
      if (i < params.length) {
        let val = String(params[i]);
        i++;
        // slurp additional words until the next token looks like a flag
        while (i < params.length && !looksLikeFlag(params[i])) {
          val += " " + String(params[i]);
          i++;
        }
        out.push(val);
      }
    } else {
      // not a flag: pass through (covers executable paths if they slip in here)
      out.push(tok);
      i++;
    }
  }
  return out;
}

// ----------------------- argv decoding -----------------------
const argv = process.argv.slice(2);

function decodeArgv() {
  // 1) --argv-json
  let i = argv.indexOf("--argv-json");
  if (i !== -1 && argv[i + 1]) {
    try {
      const arr = JSON.parse(argv[i + 1]);
      if (!Array.isArray(arr) || arr.length === 0) throw new Error();
      return arr.map(String);
    } catch {
      console.error("[wrapper] ERROR: --argv-json must be a JSON array of strings.");
      process.exit(1);
    }
  }

  // 2) --argv-b64 (base64(JSON array))
  i = argv.indexOf("--argv-b64");
  if (i !== -1 && argv[i + 1]) {
    try {
      const json = Buffer.from(argv[i + 1], "base64").toString("utf8");
      const arr = JSON.parse(json);
      if (!Array.isArray(arr) || arr.length === 0) throw new Error();
      return arr.map(String);
    } catch {
      console.error("[wrapper] ERROR: --argv-b64 must be base64 of a JSON array of strings.");
      process.exit(1);
    }
  }

  // 3) --argv-file (NUL- or newline-separated)
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
      console.error(
        `[wrapper] ERROR: --argv-file must be readable (NUL/newline-separated): ${e.message || e}`
      );
      process.exit(1);
    }
  }

  // 4) Env JSON (optional)
  if (process.env.RUST_ARGS_JSON) {
    try {
      const arr = JSON.parse(process.env.RUST_ARGS_JSON);
      if (!Array.isArray(arr) || arr.length === 0) throw new Error();
      return arr.map(String);
    } catch {
      console.error("[wrapper] ERROR: RUST_ARGS_JSON must be a JSON array of strings.");
      process.exit(1);
    }
  }

  // 5) Legacy --argv (already split by the shell)
  const flagIndex = argv.indexOf("--argv");
  if (flagIndex === -1) {
    console.error(
      "[wrapper] ERROR: Missing argv source. Use --argv-file/--argv-json/--argv-b64, RUST_ARGS_JSON, or legacy --argv."
    );
    process.exit(1);
  }
  const legacy = argv.slice(flagIndex + 1);
  if (legacy.length === 0) {
    console.error("[wrapper] ERROR: No arguments provided for RustDedicated.");
    process.exit(1);
  }
  return legacy.map(String);
}

const fullArgv = decodeArgv();
const executable = fullArgv[0];
let params = fullArgv.slice(1);

// **apply repair in JS** so split values like "Procedural" "Map" become "Procedural Map"
params = repairSplitArgs(params);

if (!executable) {
  console.error("[wrapper] ERROR: First argv element must be the RustDedicated binary.");
  process.exit(1);
}

console.log(
  `[wrapper] Executing: ${executable} ` +
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

// Spawn WITHOUT shell: exact argv preserved
const game = spawn(executable, params, {
  stdio: ["pipe", "pipe", "pipe"],
  cwd: "/home/container",
});

function mirror(chunk, isErr = false) {
  const s = chunk.toString();
  (isErr ? process.stderr : process.stdout).write(s);
  fs.appendFile(LATEST_LOG, s.replace(/\r/g, ""), () => {});
}

game.stdout.on("data", (d) => mirror(d, false));
game.stderr.on("data", (d) => mirror(d, true));

// If -logfile is set, tail it and mirror to the panel too
let tailProc = null;
if (unityLogfile) {
  try {
    fs.closeSync(fs.openSync(unityLogfile, "a"));
  } catch {}
  console.log(`[wrapper] Mirroring -logfile: ${unityLogfile}`);
  tailProc = spawn("tail", ["-n", "+1", "-F", unityLogfile], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  const tailMirror = (d) => mirror(d, false);
  tailProc.stdout.on("data", tailMirror);
  tailProc.stderr.on("data", tailMirror);
  tailProc.on("exit", (c) => console.log(`[wrapper] tail exited (${c}).`));
}

// Forward panel input → server stdin
process.stdin.setEncoding("utf8");
process.stdin.on("data", (txt) => {
  try {
    game.stdin.write(txt);
  } catch {}
});
process.stdin.resume();

// Graceful shutdown
let exited = false;
["SIGTERM", "SIGINT"].forEach((sig) => {
  process.on(sig, () => {
    if (!exited) {
      console.log(`[wrapper] ${sig} → stopping server...`);
      try {
        game.stdin.write("quit\n");
      } catch {}
      setTimeout(() => {
        try {
          game.kill("TERM");
        } catch {}
      }, 5000);
    }
  });
});

game.on("exit", (code) => {
  exited = true;
  if (tailProc && !tailProc.killed) {
    try {
      tailProc.kill("TERM");
    } catch {}
  }
  console.log(`[wrapper] Rust exited with code: ${code}`);
  process.exit(code ?? 0);
});
