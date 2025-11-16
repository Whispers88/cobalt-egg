#!/usr/bin/env node

// ============================================================================
// Rust wrapper — PTY-aware, argv-safe, logfile mirroring, panel->RCON/STDIN shim
// - If starting in CONSOLE_MODE=stdin: run Rust directly so STDIN works
// - If starting in rcon/auto: prefers launching via `script -qefc` for PTY
// - Uses `stdbuf -oL -eL` (if present) for line-buffered output
// - Pretty console formatting; mirrors raw to latest.log; tails -logfile if present
// - Panel input:
//     * "! <cmd>"      => run shell in container
//     * "stdin: <x>"   => send to Rust STDIN (console)
//     * "console: <x>" => alias of stdin
//     * "rcon: <x>"    => send via RCON (legacy or Web, based on RCON_MODE)
//     * default route  => CONSOLE_MODE=stdin|rcon|auto (auto = rcon if RCON_PASS set)
//     * ".stack"       => use gdb to pause RustDedicated, dump backtraces, resume
// - `.mode stdin|rcon|auto` switches default at runtime
// - RCON_MODE=legacy|web selects legacy RCON or WebRCON
// ============================================================================

const { spawn, execSync } = require("child_process");
const fs = require("fs");
const net = require("net");

// Optional WebSocket client for WebRCON mode
let WebSocket = null;
try {
  WebSocket = require("ws");
} catch {
  // only required for RCON_MODE=web
}

// ---------- config ----------
const LATEST_LOG = process.env.LATEST_LOG || "/home/container/latest.log";
const RCON_HOST = process.env.RCON_HOST || "127.0.0.1";
const RCON_PORT = parseInt(process.env.RCON_PORT || "28016", 10);
const RCON_PASS = process.env.RCON_PASS || "";
const RCON_MODE = (process.env.RCON_MODE || "legacy").toLowerCase(); // legacy | web

const initialMode = (process.env.CONSOLE_MODE || "auto").toLowerCase();
const COLOR_OK = process.stdout.isTTY && !("NO_COLOR" in process.env);

// ---------- colors ----------
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
  : {
      reset: "",
      dim: "",
      fg: { red: "", green: "", yellow: "", cyan: "", magenta: "", white: "" },
    };

// ---------- helpers ----------
const hhmm = () => {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `${p(d.getHours())}:${p(d.getMinutes())}`;
};

const looksLikeFlag = (s) =>
  typeof s === "string" && /^[-+][A-Za-z0-9_.-]+$/.test(s);

const SWITCH_ONLY = new Set(["-batchmode", "-nographics", "-nolog", "-no-gui"]);

const which = (bin) => {
  try {
    return execSync(`command -v ${bin}`, {
      stdio: ["ignore", "pipe", "ignore"],
    })
      .toString()
      .trim();
  } catch {
    return "";
  }
};

const shQuote = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;

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

function tagForLine(s) {
  const t = s.toLowerCase();
  if (t.includes("oxide") || t.includes("umod")) return "[oxide]";
  if (t.includes("carbon")) return "[carbon]";
  return "";
}

// ---------- log file setup ----------
try {
  if (fs.existsSync(LATEST_LOG)) {
    fs.renameSync(LATEST_LOG, `${LATEST_LOG}.prev`);
  }
} catch {}

try {
  fs.writeFileSync(LATEST_LOG, "", { flag: "w" });
} catch {}

// ---------- argv decode ----------
const argv = process.argv.slice(2);

function decodeArgv() {
  let i = argv.indexOf("--argv-json");
  if (i !== -1 && argv[i + 1]) {
    try {
      const arr = JSON.parse(argv[i + 1]);
      if (!Array.isArray(arr) || !arr.length) throw 0;
      return arr.map(String);
    } catch {
      console.error(
        `${hhmm()} ERROR: --argv-json must be a JSON array of strings.`,
      );
      process.exit(1);
    }
  }

  i = argv.indexOf("--argv-b64");
  if (i !== -1 && argv[i + 1]) {
    try {
      const json = Buffer.from(argv[i + 1], "base64").toString("utf8");
      const arr = JSON.parse(json);
      if (!Array.isArray(arr) || !arr.length) throw 0;
      return arr.map(String);
    } catch {
      console.error(
        `${hhmm()} ERROR: --argv-b64 must be base64 of a JSON array of strings.`,
      );
      process.exit(1);
    }
  }

  i = argv.indexOf("--argv-file");
  if (i !== -1 && argv[i + 1]) {
    try {
      const buf = fs.readFileSync(argv[i + 1]);
      let parts = buf
        .toString("utf8")
        .split("\0")
        .filter(Boolean);
      if (parts.length <= 1)
        parts = buf
          .toString("utf8")
          .split(/\r?\n/)
          .filter(Boolean);
      if (!parts.length) throw new Error("empty argv file");
      return parts.map(String);
    } catch (e) {
      console.error(
        `${hhmm()} ERROR: --argv-file must be readable: ${e.message || e}`,
      );
      process.exit(1);
    }
  }

  if (process.env.RUST_ARGS_JSON) {
    try {
      const arr = JSON.parse(process.env.RUST_ARGS_JSON);
      if (!Array.isArray(arr) || !arr.length) throw 0;
      return arr.map(String);
    } catch {
      console.error(
        `${hhmm()} ERROR: RUST_ARGS_JSON must be a JSON array of strings.`,
      );
      process.exit(1);
    }
  }

  const flagIndex = argv.indexOf("--argv");
  if (flagIndex === -1) {
    console.error(
      `${hhmm()} ERROR: Missing argv source. Use --argv-file/--argv-json/--argv-b64 or legacy --argv.`,
    );
    process.exit(1);
  }

  const legacy = argv.slice(flagIndex + 1);
  if (!legacy.length) {
    console.error(
      `${hhmm()} ERROR: No arguments provided for RustDedicated.`,
    );
    process.exit(1);
  }
  return legacy.map(String);
}

const fullArgv = decodeArgv();
const executable = fullArgv[0];
let params = fullArgv.slice(1);
params = repairSplitArgs(params);

if (!executable) {
  console.error(
    `${hhmm()} ERROR: First argv element must be the RustDedicated binary.`,
  );
  process.exit(1);
}

// ---------- run line ----------
const CONSOLE_MODE = (() => {
  let m = initialMode;
  if (m !== "stdin" && m !== "rcon" && m !== "auto") m = "auto";
  return m;
})();
process.env.CONSOLE_MODE = CONSOLE_MODE;

process.stdout.write(
  `${C.dim}${hhmm()}${C.reset} Executing: ${executable} ` +
    params
      .map((a) =>
        /[^A-Za-z0-9_/.:-]/.test(a) ? `"${a.replace(/"/g, '\\"')}"` : a,
      )
      .join(" ") +
    `  [mode:${process.env.CONSOLE_MODE}]` +
    "\n",
);

// detect -logfile
let unityLogfile = null;
for (let i = 0; i < params.length; i++) {
  if (params[i] === "-logfile" && i + 1 < params.length) {
    unityLogfile = params[i + 1];
    break;
  }
}

// ---------- pretty mirroring ----------
const buffers = Object.create(null);

function emitPretty(sourceKey, chunk, isErr = false) {
  const key = sourceKey + (isErr ? ":err" : ":out");
  const prev = buffers[key] || "";
  const raw = chunk.toString();

  try {
    fs.appendFile(LATEST_LOG, raw.replace(/\r/g, ""), () => {});
  } catch {}

  const s = prev + raw;
  const lines = s.split(/\r?\n/);
  buffers[key] = lines.pop();

  for (const ln of lines) {
    const label = tagForLine(ln);
    const color =
      label === "[oxide]"
        ? C.fg.magenta
        : label === "[carbon]"
          ? C.fg.cyan
          : isErr
            ? C.fg.red
            : C.fg.green;
    const out = `${C.dim}${hhmm()}${C.reset} ${
      label ? label + " " : ""
    }${ln}`;
    (isErr ? process.stderr : process.stdout).write(
      `${color}${out}${C.reset}\n`,
    );
  }
}

// ---------- spawn Rust with or without PTY ----------
const scriptBin = which("script"); // util-linux
const stdbufBin = which("stdbuf"); // coreutils

// If we *start* in stdin mode, prefer a direct pipe so game.stdin is really Rust's stdin.
const forcePlainStdin = initialMode === "stdin";

let cmd;
let args;

// Build the real command to run (optionally prefixed with stdbuf)
const realCmd = (() => {
  const seq = [];
  if (stdbufBin) seq.push(stdbufBin, "-oL", "-eL");
  seq.push(executable, ...params);
  return seq.map(shQuote).join(" ");
})();

if (scriptBin && !forcePlainStdin) {
  // RCON / auto modes: run under a PTY: script -qefc "<realCmd>" /dev/null
  cmd = scriptBin;
  args = ["-qefc", realCmd, "/dev/null"];
  process.stdout.write(
    `${C.dim}${hhmm()}${C.reset} using PTY via 'script'${
      stdbufBin ? " + stdbuf" : ""
    }\n`,
  );
} else if (stdbufBin) {
  // stdin mode (or no script): run RustDedicated directly, with stdbuf if available
  cmd = stdbufBin;
  args = ["-oL", "-eL", executable, ...params];
  process.stdout.write(
    `${C.dim}${hhmm()}${C.reset} running without PTY (using stdbuf)\n`,
  );
} else {
  cmd = executable;
  args = params;
  process.stdout.write(
    `${C.dim}${hhmm()}${C.reset} running plain (no script, no stdbuf)\n`,
  );
}

const game = spawn(cmd, args, {
  stdio: ["pipe", "pipe", "pipe"],
  cwd: "/home/container",
  shell: false,
});

game.stdout.on("data", (d) => emitPretty("game", d, false));
game.stderr.on("data", (d) => emitPretty("game", d, true));

// tail unity -logfile
let tailProc = null;
if (unityLogfile) {
  try {
    fs.closeSync(fs.openSync(unityLogfile, "a"));
  } catch {}

  process.stdout.write(
    `${C.dim}${hhmm()}${C.reset} Mirroring logfile: ${unityLogfile}\n`,
  );
  tailProc = spawn("tail", ["-n", "+1", "-F", unityLogfile], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  const tailMirror = (d) => emitPretty("unity", d, false);
  tailProc.stdout.on("data", tailMirror);
  tailProc.stderr.on("data", tailMirror);
} else {
  process.stdout.write(
    `${C.dim}${hhmm()}${C.reset} No -logfile specified; consider adding: -logfile /home/container/unity.log\n`,
  );
}

// ---------- helper to resolve actual RustDedicated PID ----------
function resolveRustPid(callback) {
  if (!game || game.killed) {
    callback(null);
    return;
  }

  // If we're *not* going through `script`, game.pid is RustDedicated.
  if (!scriptBin || forcePlainStdin) {
    callback(game.pid);
    return;
  }

  // Otherwise, find RustDedicated via pgrep.
  const ps = spawn("pgrep", ["-f", "RustDedicated"], {
    stdio: ["ignore", "pipe", "pipe"],
  });

  let out = "";
  ps.stdout.on("data", (d) => (out += d.toString()));

  ps.on("exit", (code) => {
    if (code !== 0) {
      callback(null);
      return;
    }
    const tokens = out.trim().split(/\s+/);
    const pidStr = tokens[tokens.length - 1];
    const pid = parseInt(pidStr, 10);
    if (!pid || Number.isNaN(pid)) {
      callback(null);
    } else {
      callback(pid);
    }
  });

  ps.on("error", () => callback(null));
}

// ---------- RCON helpers (persistent; legacy + optional WebRCON) ----------
const SERVERDATA_AUTH = 3;
const SERVERDATA_EXECCOMMAND = 2;

function pkt(id, type, body) {
  const b = Buffer.from(String(body), "utf8");
  const len = 4 + 4 + b.length + 2;
  const buf = Buffer.alloc(4 + len);
  buf.writeInt32LE(len, 0);
  buf.writeInt32LE(id, 4);
  buf.writeInt32LE(type, 8);
  b.copy(buf, 12);
  buf.writeInt8(0, 12 + b.length);
  buf.writeInt8(0, 13 + b.length);
  return buf;
}

// --- legacy RCON (Source-style TCP) ---
let rconSocket = null;
let rconReady = false;

function ensureLegacyRconConnection() {
  return new Promise((resolve, reject) => {
    if (!RCON_PASS) return reject(new Error("RCON_PASS not set"));

    if (rconSocket && rconReady) return resolve(rconSocket);

    if (rconSocket && !rconReady) {
      let tries = 0;
      const waitReady = () => {
        if (rconReady && rconSocket) return resolve(rconSocket);
        if (!rconSocket) return reject(new Error("RCON socket lost"));
        if (tries++ > 40) return reject(new Error("RCON auth timeout"));
        setTimeout(waitReady, 50);
      };
      return waitReady();
    }

    const socket = net.createConnection(
      { host: RCON_HOST, port: RCON_PORT },
      () => {
        try {
          socket.write(pkt(1, SERVERDATA_AUTH, RCON_PASS));
        } catch (e) {
          return reject(e);
        }
      },
    );

    rconSocket = socket;
    rconReady = false;

    socket.on("data", () => {
      if (!rconReady) {
        rconReady = true;
        process.stdout.write(
          `${C.dim}${hhmm()}${C.reset} [rcon] legacy connection authed\n`,
        );
      }
      // Ignore body; server logs output anyway.
    });

    socket.on("error", (e) => {
      process.stdout.write(
        `${C.fg.red}${hhmm()} [rcon] legacy socket error: ${e.message}${C.reset}\n`,
      );
      rconReady = false;
      rconSocket = null;
    });

    socket.on("close", () => {
      process.stdout.write(
        `${C.dim}${hhmm()}${C.reset} [rcon] legacy connection closed\n`,
      );
      rconReady = false;
      rconSocket = null;
    });

    let tries = 0;
    const waitReady2 = () => {
      if (rconReady && rconSocket) return resolve(rconSocket);
      if (!rconSocket) return reject(new Error("RCON connection failed"));
      if (tries++ > 40) return reject(new Error("RCON auth timeout"));
      setTimeout(waitReady2, 50);
    };
    waitReady2();
  });
}

function sendLegacyRconOnce(cmdTxt) {
  if (!RCON_PASS || !cmdTxt.trim()) return Promise.resolve();
  return ensureLegacyRconConnection().then((socket) => {
    return new Promise((resolve, reject) => {
      try {
        const id = Date.now() & 0x7fffffff;
        socket.write(pkt(id, SERVERDATA_EXECCOMMAND, cmdTxt));
        resolve();
      } catch (e) {
        reject(e);
      }
    });
  });
}

// --- WebRCON (WebSocket JSON) ---
let webRconSocket = null;
let webRconReady = false;

function ensureWebRconConnection() {
  return new Promise((resolve, reject) => {
    if (!RCON_PASS) return reject(new Error("RCON_PASS not set"));
    if (!WebSocket) {
      return reject(
        new Error("WebRCON mode requires 'ws' package (npm install ws)"),
      );
    }

    if (webRconSocket && webRconReady) return resolve(webRconSocket);

    if (webRconSocket && !webRconReady) {
      let tries = 0;
      const waitReady = () => {
        if (webRconReady && webRconSocket) return resolve(webRconSocket);
        if (!webRconSocket) return reject(new Error("WebRCON socket lost"));
        if (tries++ > 40) return reject(new Error("WebRCON connect timeout"));
        setTimeout(waitReady, 50);
      };
      return waitReady();
    }

    const url = `ws://${RCON_HOST}:${RCON_PORT}/${encodeURIComponent(
      RCON_PASS,
    )}`;
    const ws = new WebSocket(url);

    webRconSocket = ws;
    webRconReady = false;

    ws.on("open", () => {
      webRconReady = true;
      process.stdout.write(
        `${C.dim}${hhmm()}${C.reset} [rcon] WebRCON connected\n`,
      );
      resolve(ws);
    });

    ws.on("message", (data) => {
      try {
        const txt = data.toString("utf8");

        // Rust WebRCON sends JSON: { Identifier, Message, Type, ... }
        let obj = null;
        try {
          obj = JSON.parse(txt);
        } catch {
          obj = null;
        }

        let payload = "";

        if (obj && typeof obj.Message === "string") {
          payload = obj.Message;
        } else {
          // fallback: treat raw text as the body
          payload = txt;
        }

        // Clean & split into lines
        payload = payload.replace(/[\x00-\x08\x0B-\x1F\x7F]/g, "");
        const lines = payload.split(/\r?\n/);

        for (const ln of lines) {
          const trimmed = ln.trim();
          if (!trimmed) continue;

          // Ignore only lines that start with "[oxide]" (oxide already logs to console)
          if (trimmed.startsWith("[oxide]")) {
            continue;
          }

          const out = `${C.dim}${hhmm()}${C.reset} [rcon] ${ln}`;
          process.stdout.write(`${C.fg.cyan}${out}${C.reset}\n`);
        }
      } catch (e) {
        process.stdout.write(
          `${C.fg.red}${hhmm()} [rcon] WebRCON message decode error: ${e.message}${C.reset}\n`,
        );
      }
    });

    ws.on("error", (e) => {
      process.stdout.write(
        `${C.fg.red}${hhmm()} [rcon] WebRCON error: ${e.message}${C.reset}\n`,
      );
      webRconReady = false;
      webRconSocket = null;
    });

    ws.on("close", () => {
      process.stdout.write(
        `${C.dim}${hhmm()}${C.reset} [rcon] WebRCON closed\n`,
      );
      webRconReady = false;
      webRconSocket = null;
    });

    let tries = 0;
    const waitReady2 = () => {
      if (webRconReady && webRconSocket) return resolve(webRconSocket);
      if (!webRconSocket) return reject(new Error("WebRCON connection failed"));
      if (tries++ > 80) return reject(new Error("WebRCON connect timeout"));
      setTimeout(waitReady2, 50);
    };
    waitReady2();
  });
}

function sendWebRconOnce(cmdTxt) {
  if (!RCON_PASS || !cmdTxt.trim()) return Promise.resolve();
  return ensureWebRconConnection().then((ws) => {
    return new Promise((resolve, reject) => {
      try {
        const id = Date.now() & 0x7fffffff;
        const payload = {
          Identifier: id,
          Message: cmdTxt,
          Name: "WebRcon",
        };
        ws.send(JSON.stringify(payload), (err) => {
          if (err) return reject(err);
          resolve();
        });
      } catch (e) {
        reject(e);
      }
    });
  });
}

// --- unified sendRconOnce (picks legacy vs WebRCON) ---
function sendRconOnce(cmdTxt) {
  if (!RCON_PASS || !cmdTxt.trim()) return Promise.resolve();

  if (RCON_MODE === "web") {
    return sendWebRconOnce(cmdTxt);
  }

  // default: legacy
  return sendLegacyRconOnce(cmdTxt);
}

// ---------- panel input handler ----------
process.stdin.setEncoding("utf8");
let stdinBuf = "";

process.stdin.on("data", (txt) => {
  stdinBuf += txt;
  const lines = stdinBuf.split(/\r?\n/);
  stdinBuf = lines.pop();

  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line) continue;

    // 1) Shell passthrough
    if (line.startsWith("!")) {
      const sh = line.slice(1).trim();
      if (!sh) {
        process.stdout.write(
          `${C.fg.yellow}${hhmm()} [shell] (empty)${C.reset}\n`,
        );
        continue;
      }
      process.stdout.write(
        `${C.dim}${hhmm()}${C.reset} [shell] ${sh}\n`,
      );
      const shProc = spawn("bash", ["-lc", sh], {
        stdio: ["ignore", "pipe", "pipe"],
      });
      shProc.stdout.on("data", (d) => process.stdout.write(`${d}`));
      shProc.stderr.on("data", (d) => process.stderr.write(`${d}`));
      shProc.on("exit", (code) =>
        process.stdout.write(
          `${C.dim}${hhmm()}${C.reset} [shell] exit ${code}\n`,
        ),
      );
      continue;
    }

    // 2) Runtime default mode toggle
    if (line.toLowerCase().startsWith(".mode ")) {
      const m = line.split(/\s+/, 2)[1]?.toLowerCase();
      if (m === "stdin" || m === "rcon" || m === "auto") {
        process.env.CONSOLE_MODE = m;
        process.stdout.write(
          `${C.dim}${hhmm()}${C.reset} [mode] default set to ${m}\n`,
        );
      } else {
        process.stdout.write(
          `${C.dim}${hhmm()}${C.reset} [mode] use: .mode stdin | rcon | auto\n`,
        );
      }
      continue;
    }

    // 2b) Stack trace request via gdb (pause, dump, resume) on real RustDedicated PID
    if (line.toLowerCase() === ".stack") {
      resolveRustPid((pid) => {
        if (!pid) {
          process.stdout.write(
            `${C.fg.red}${hhmm()} [stack] could not resolve RustDedicated PID (is the server running?)${C.reset}\n`,
          );
          return;
        }

        process.stdout.write(
          `${C.dim}${hhmm()}${C.reset} [stack] running gdb backtrace on pid ${pid}\n`,
        );

        const bt = spawn(
          "gdb",
          ["-batch", "-ex", "thread apply all bt", "-p", String(pid)],
          {
            stdio: ["ignore", "pipe", "pipe"],
          },
        );

        let stderrBuf = "";

        bt.stdout.on("data", (d) => {
          process.stdout.write(
            `${C.dim}${hhmm()}${C.reset} [gdb] ${d.toString()}`,
          );
        });

        bt.stderr.on("data", (d) => {
          const s = d.toString();
          stderrBuf += s;
          process.stdout.write(
            `${C.fg.red}${hhmm()} [gdb] ${s}${C.reset}`,
          );
        });

        bt.on("exit", (code) => {
          if (/Operation not permitted/.test(stderrBuf)) {
            process.stdout.write(
              `${C.fg.red}${hhmm()} [stack] gdb could not attach (ptrace blocked by host/container security).${C.reset}\n`,
            );
          } else {
            process.stdout.write(
              `${C.dim}${hhmm()}${C.reset} [stack] gdb exited with code ${code}\n`,
            );
          }
        });
      });

      continue;
    }

    // 3) Explicit routing prefixes
    let route = (process.env.CONSOLE_MODE || "auto").toLowerCase();
    let payload = line;

    if (line.toLowerCase().startsWith("stdin:")) {
      route = "stdin";
      payload = line.slice(6).trimStart();
    } else if (line.toLowerCase().startsWith("console:")) {
      route = "stdin";
      payload = line.slice(8).trimStart();
    } else if (line.toLowerCase().startsWith("rcon:")) {
      route = "rcon";
      payload = line.slice(5).trimStart();
    }

    // 4) Resolve "auto" and missing RCON
    if (route === "auto") route = RCON_PASS ? "rcon" : "stdin";
    if (route === "rcon" && !RCON_PASS) {
      process.stdout.write(
        `${C.dim}${hhmm()}${C.reset} [rcon] disabled (no pass); using stdin\n`,
      );
      route = "stdin";
    }

    // 5) Dispatch
    if (route === "stdin") {
      try {
        game.stdin.write(payload + "\n");
        process.stdout.write(
          `${C.dim}${hhmm()}${C.reset} [stdin] ${payload}\n`,
        );
      } catch {
        process.stdout.write(
          `${C.fg.red}${hhmm()} [stdin] failed to write${C.reset}\n`,
        );
      }
    } else {
      // route === "rcon"
      sendRconOnce(payload).catch((e) => {
        process.stdout.write(
          `${C.fg.red}${hhmm()} [rcon] ${payload} -> ${e.message}${C.reset}\n`,
        );
      });
    }
  }
});

process.stdin.resume();

// ---------- signals ----------
let exited = false;

["SIGTERM", "SIGINT"].forEach((sig) => {
  process.on(sig, () => {
    if (!exited) {
      const line = `${C.dim}${hhmm()}${C.reset} stopping server...`;
      process.stdout.write(`${line}\n`);
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

  // flush any partial buffered line fragments
  for (const k of Object.keys(buffers)) {
    const rem = buffers[k];
    if (!rem) continue;
    const label = tagForLine(rem);
    const color =
      label === "[oxide]"
        ? C.fg.magenta
        : label === "[carbon]"
          ? C.fg.cyan
          : C.fg.white;
    const out = `${C.dim}${hhmm()}${C.reset} ${
      label ? label + " " : ""
    }${rem}`;
    process.stdout.write(`${color}${out}${C.reset}\n`);
    buffers[k] = "";
  }

  const summary = `${C.dim}${hhmm()}${C.reset} exited with code: ${code}`;
  process.stdout.write(`${summary}\n`);
  process.exit(code ?? 0);
});
