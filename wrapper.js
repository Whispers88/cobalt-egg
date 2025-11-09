#!/usr/bin/env node

// ============================================================================
// Rust wrapper — argv-safe + logfile mirroring + panel->RCON/STDIN shim
// - Pretty console with [oxide]/[carbon] tags
// - Mirrors RAW to latest.log; tails -logfile if present
// - Panel input:
//     * "!" prefix => run as shell in container
//     * "stdin:" prefix => send to Rust stdin
//     * otherwise => send via RCON (if RCON_PASS set) or stdin fallback
// - Now prints RCON response payloads
// ============================================================================

const { spawn } = require("child_process");
const fs = require("fs");
const net = require("net");

// ---------- config ----------
const LATEST_LOG = process.env.LATEST_LOG || "/home/container/latest.log";
const RCON_HOST = process.env.RCON_HOST || "127.0.0.1";
const RCON_PORT = parseInt(process.env.RCON_PORT || "28016", 10);
const RCON_PASS = process.env.RCON_PASS || "";
const CONSOLE_MODE = RCON_PASS ? "rcon" : "stdin"; // auto choose if no pass
const COLOR_OK = process.stdout.isTTY && !("NO_COLOR" in process.env);

// ---------- colors ----------
const C = COLOR_OK
  ? { reset: "\x1b[0m", dim: "\x1b[2m",
      fg: { red: "\x1b[31m", green: "\x1b[32m", yellow: "\x1b[33m",
            cyan: "\x1b[36m", magenta: "\x1b[35m", white: "\x1b[37m" } }
  : { reset: "", dim: "", fg: { red: "", green: "", yellow: "", cyan: "", magenta: "", white: "" } };

// ---------- helpers ----------
const hhmm = () => { const d = new Date(); const p = n => String(n).padStart(2,"0"); return `${p(d.getHours())}:${p(d.getMinutes())}`; };
const looksLikeFlag = (s) => typeof s === "string" && /^[-+][A-Za-z0-9_.-]+$/.test(s);
const SWITCH_ONLY = new Set(["-batchmode","-nographics","-nolog","-no-gui"]);

function repairSplitArgs(params){
  const out=[]; for(let i=0;i<params.length;){
    const tok=String(params[i]);
    if(looksLikeFlag(tok)){ out.push(tok); i++; if(SWITCH_ONLY.has(tok)) continue;
      if(i<params.length){ let val=String(params[i++]);
        while(i<params.length && !looksLikeFlag(params[i])) val+=" "+String(params[i++]);
        out.push(val);
      }
    } else { out.push(tok); i++; }
  } return out;
}
function tagForLine(s){ const t=s.toLowerCase(); if(t.includes("oxide")||t.includes("umod"))return"[oxide]"; if(t.includes("carbon"))return"[carbon]"; return ""; }

// ---------- log file setup ----------
try { if (fs.existsSync(LATEST_LOG)) fs.renameSync(LATEST_LOG, `${LATEST_LOG}.prev`); } catch {}
try { fs.writeFileSync(LATEST_LOG, "", { flag: "w" }); } catch {}

// ---------- argv decode ----------
const argv = process.argv.slice(2);
function decodeArgv(){
  let i = argv.indexOf("--argv-json");
  if(i!==-1 && argv[i+1]){ try{ const arr=JSON.parse(argv[i+1]); if(!Array.isArray(arr)||!arr.length)throw 0; return arr.map(String);}catch{console.error(`${hhmm()} ERROR: --argv-json must be a JSON array of strings.`); process.exit(1);} }
  i = argv.indexOf("--argv-b64");
  if(i!==-1 && argv[i+1]){ try{ const json=Buffer.from(argv[i+1],"base64").toString("utf8"); const arr=JSON.parse(json); if(!Array.isArray(arr)||!arr.length)throw 0; return arr.map(String);}catch{console.error(`${hhmm()} ERROR: --argv-b64 must be base64 of a JSON array of strings.`); process.exit(1);} }
  i = argv.indexOf("--argv-file");
  if(i!==-1 && argv[i+1]){ try{ const buf=fs.readFileSync(argv[i+1]); let parts=buf.toString("utf8").split("\0").filter(Boolean); if(parts.length<=1) parts=buf.toString("utf8").split(/\r?\n/).filter(Boolean); if(!parts.length) throw new Error("empty argv file"); return parts.map(String);}catch(e){console.error(`${hhmm()} ERROR: --argv-file must be readable: ${e.message||e}`); process.exit(1);} }
  if(process.env.RUST_ARGS_JSON){ try{ const arr=JSON.parse(process.env.RUST_ARGS_JSON); if(!Array.isArray(arr)||!arr.length)throw 0; return arr.map(String);}catch{console.error(`${hhmm()} ERROR: RUST_ARGS_JSON must be a JSON array of strings.`); process.exit(1);} }
  const flagIndex = argv.indexOf("--argv");
  if(flagIndex===-1){ console.error(`${hhmm()} ERROR: Missing argv source. Use --argv-file/--argv-json/--argv-b64 or legacy --argv.`); process.exit(1); }
  const legacy = argv.slice(flagIndex+1);
  if(!legacy.length){ console.error(`${hhmm()} ERROR: No arguments provided for RustDedicated.`); process.exit(1); }
  return legacy.map(String);
}
const fullArgv = decodeArgv();
const executable = fullArgv[0];
let params = fullArgv.slice(1);
params = repairSplitArgs(params);
if(!executable){ console.error(`${hhmm()} ERROR: First argv element must be the RustDedicated binary.`); process.exit(1); }

// ---------- run line ----------
process.stdout.write(
  `${C.dim}${hhmm()}${C.reset} Executing: ${executable} ` +
  params.map(a => (/[^A-Za-z0-9_/.:-]/.test(a)?`"${a}"`:a)).join(" ") +
  `  [console:${CONSOLE_MODE}]` + "\n"
);

// detect -logfile
let unityLogfile = null;
for(let i=0;i<params.length;i++){ if(params[i]==="-logfile" && i+1<params.length){ unityLogfile=params[i+1]; break; }}

// ---------- pretty mirroring ----------
const buffers = Object.create(null);
function emitPretty(sourceKey, chunk, isErr=false){
  const key = sourceKey + (isErr?":err":":out");
  const prev = buffers[key] || "";
  const raw  = chunk.toString();

  try { fs.appendFile(LATEST_LOG, raw.replace(/\r/g,""), ()=>{}); } catch {}

  const s = prev + raw;
  const lines = s.split(/\r?\n/);
  buffers[key] = lines.pop();

  for(const ln of lines){
    const label = tagForLine(ln);
    const color = label==="[oxide]"?C.fg.magenta : label==="[carbon]"?C.fg.cyan : isErr?C.fg.red : C.fg.green;
    const out = `${C.dim}${hhmm()}${C.reset} ${label?label+" ":""}${ln}`;
    (isErr?process.stderr:process.stdout).write(`${color}${out}${C.reset}\n`);
  }
}

// ---------- spawn Rust ----------
const game = spawn(executable, params, { stdio: ["pipe","pipe","pipe"], cwd: "/home/container" });
game.stdout.on("data", d => emitPretty("game", d, false));
game.stderr.on("data", d => emitPretty("game", d, true));

// tail unity -logfile
let tailProc=null;
if(unityLogfile){
  try { fs.closeSync(fs.openSync(unityLogfile,"a")); } catch {}
  process.stdout.write(`${C.dim}${hhmm()}${C.reset} Mirroring logfile: ${unityLogfile}\n`);
  tailProc = spawn("tail", ["-n","+1","-F", unityLogfile], { stdio: ["ignore","pipe","pipe"] });
  const tailMirror = d => emitPretty("unity", d, false);
  tailProc.stdout.on("data", tailMirror);
  tailProc.stderr.on("data", tailMirror);
}

// ---------- RCON helpers ----------
const SERVERDATA_AUTH=3, SERVERDATA_EXECCOMMAND=2;
function pkt(id,type,body){
  const b=Buffer.from(String(body),"utf8");
  const len=4+4+b.length+2;
  const buf=Buffer.alloc(4+len);
  buf.writeInt32LE(len,0); buf.writeInt32LE(id,4); buf.writeInt32LE(type,8);
  b.copy(buf,12); buf.writeInt8(0,12+b.length); buf.writeInt8(0,13+b.length);
  return buf;
}
function sendRconOnce(cmd){
  return new Promise((resolve,reject)=>{
    const s=net.createConnection({host:RCON_HOST,port:RCON_PORT},()=>{
      s.write(pkt(1,SERVERDATA_AUTH,RCON_PASS));
      setTimeout(()=>s.write(pkt(2,SERVERDATA_EXECCOMMAND,cmd)),150);
    });
    const chunks=[];
    s.on("data",d=>chunks.push(d));
    s.on("error",e=>reject(e));
    s.setTimeout(4000,()=>{ try{s.destroy();}catch{} reject(new Error("rcon timeout")); });
    setTimeout(()=>{ try{s.end();}catch{} resolve(Buffer.concat(chunks)); },650);
  });
}
function decodeRconBuffer(buf){
  // Naive: try to locate UTF-8 text after header(s)
  // Many servers echo back multiple packets; just strip non-printables and show text.
  const txt = buf.toString("utf8").replace(/[\x00-\x08\x0B-\x1F\x7F]/g, "");
  return txt.trim();
}

// ---------- panel input handler ----------
// Prefixes:
//   "! <cmd>"     => shell in container
//   "stdin: <x>"  => write to game stdin
//   default       => RCON (if pass set) else stdin
process.stdin.setEncoding("utf8");
let stdinBuf="";
process.stdin.on("data", (txt)=>{
  stdinBuf += txt;
  const lines = stdinBuf.split(/\r?\n/);
  stdinBuf = lines.pop();
  for(const rawLine of lines){
    const line = rawLine.trim();
    if(!line) continue;

    // Shell escape
    if(line.startsWith("!")){
      const sh = line.slice(1).trim();
      if(!sh){ process.stdout.write(`${C.fg.yellow}${hhmm()} [shell] (empty)${C.reset}\n`); continue; }
      process.stdout.write(`${C.dim}${hhmm()}${C.reset} [shell] ${sh}\n`);
      const shProc = spawn("bash", ["-lc", sh], { stdio: ["ignore","pipe","pipe"] });
      shProc.stdout.on("data", d => process.stdout.write(`${d}`));
      shProc.stderr.on("data", d => process.stderr.write(`${d}`));
      shProc.on("exit", code => process.stdout.write(`${C.dim}${hhmm()}${C.reset} [shell] exit ${code}\n`));
      continue;
    }

    // Explicit stdin:
    if(line.toLowerCase().startsWith("stdin:")){
      const payload = line.slice(6).trimStart();
      try { game.stdin.write(payload + "\n"); }
      catch { process.stdout.write(`${C.fg.red}${hhmm()} [stdin] failed to write${C.reset}\n`); }
      continue;
    }

    // Default path: RCON if possible, else stdin
    if(CONSOLE_MODE === "rcon"){
      sendRconOnce(line)
        .then(buf=>{
          const body = decodeRconBuffer(buf);
          if(body) {
            // print each line nicely
            for(const l of body.split(/\r?\n/)){
              if(!l.trim()) continue;
              process.stdout.write(`${C.dim}${hhmm()}${C.reset} [rcon] ${l}\n`);
            }
          } else {
            process.stdout.write(`${C.dim}${hhmm()}${C.reset} [rcon] (no response)\n`);
          }
        })
        .catch(e => process.stdout.write(`${C.fg.red}${hhmm()} [rcon] ${line} -> ${e.message}${C.reset}\n`));
    } else {
      try { game.stdin.write(line + "\n"); }
      catch { process.stdout.write(`${C.fg.red}${hhmm()} [stdin] failed to write${C.reset}\n`); }
    }
  }
});
process.stdin.resume();

// ---------- signals ----------
let exited=false;
["SIGTERM","SIGINT"].forEach(sig=>{
  process.on(sig, ()=>{
    if(!exited){
      const line=`${C.dim}${hhmm()}${C.reset} stopping server...`;
      process.stdout.write(`${line}\n`);
      try{ game.stdin.write("quit\n"); }catch{}
      setTimeout(()=>{ try{ game.kill("TERM"); }catch{} }, 5000);
    }
  });
});

game.on("exit", (code)=>{
  exited=true;
  if(tailProc && !tailProc.killed){ try{ tailProc.kill("TERM"); }catch{} }
  for(const k of Object.keys(buffers)){
    const rem=buffers[k]; if(!rem) continue;
    const label=tagForLine(rem);
    const color=label==="[oxide]"?C.fg.magenta:label==="[carbon]"?C.fg.cyan:C.fg.white;
    const out=`${C.dim}${hhmm()}${C.reset} ${label?label+" ":""}${rem}`;
    process.stdout.write(`${color}${out}${C.reset}\n`);
    buffers[k]="";
  }
  const summary=`${C.dim}${hhmm()}${C.reset} exited with code: ${code}`;
  process.stdout.write(`${summary}\n`);
  process.exit(code ?? 0);
});
