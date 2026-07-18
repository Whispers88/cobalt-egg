#!/usr/bin/env node
"use strict";
// Wrapper e2e: spawn wrapper.js against mock-rust.js and drive the panel stdin.
//   1. happy path: read channel, matched rcon responses, broadcast suppression,
//      catalog, pin/unpin, wipe staging, log rotation, graceful rcon quit
//   2. rcon down (bad pass) -> stdin quit fallback
//   3. quit ignored -> SHUTDOWN_TIMEOUT escalation to SIGTERM
//   4. .rollback staging via fake steamcmd -> pending_rollback + pin
const assert = require("assert");
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");

const ROOT = path.resolve(__dirname, "..");
const WRAPPER = path.join(ROOT, "wrapper.js");
const MOCK = path.join(__dirname, "mock-rust.js");
const FAKE_STEAMCMD = path.join(__dirname, "fake-steamcmd.js");
const NODE = process.execPath;
let portCounter = 28900 + (process.pid % 400);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function mkHome() {
  const h = fs.mkdtempSync(path.join(os.tmpdir(), "cobalt-e2e-"));
  fs.mkdirSync(path.join(h, "steamapps"), { recursive: true });
  fs.mkdirSync(path.join(h, ".cobalt"), { recursive: true });
  return h;
}
function writeAcf(h, buildid) {
  fs.writeFileSync(path.join(h, "steamapps", "appmanifest_258550.acf"),
    `"AppState"\n{\n\t"appid"\t\t"258550"\n\t"buildid"\t\t"${buildid}"\n` +
    `\t"InstalledDepots"\n\t{\n\t\t"258551"\n\t\t{\n\t\t\t"manifest"\t\t"7777777777"\n\t\t\t"size"\t\t"1"\n\t\t}\n\t}\n}\n`);
}

class Run {
  constructor(home, { pass = "testpass", envExtra = {}, mockArgs = [], color = false } = {}) {
    this.port = portCounter++;
    this.out = "";
    const args = [WRAPPER, "--argv", NODE, MOCK,
      "-logfile", path.join(home, "unity.log"),
      "+rcon.port", String(this.port), "+rcon.password", "testpass", ...mockArgs];
    const baseEnv = { ...process.env, COBALT_HOME: home };
    if (color) delete baseEnv.NO_COLOR; else baseEnv.NO_COLOR = "1";
    this.p = spawn(NODE, args, {
      env: {
        ...baseEnv,
        RCON_HOST: "127.0.0.1", RCON_PORT: String(this.port), RCON_PASS: pass,
        SHUTDOWN_TIMEOUT_SEC: "15", UPDATE_CHECK_INTERVAL_SEC: "0", TELEMETRY_INTERVAL_SEC: "0",
        ...envExtra,
      },
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.p.stdout.on("data", (d) => { this.out += d; if (process.env.E2E_VERBOSE) process.stdout.write(d); });
    this.p.stderr.on("data", (d) => { this.out += d; if (process.env.E2E_VERBOSE) process.stderr.write(d); });
    this.exitP = new Promise((r) => this.p.on("exit", (c) => r(c)));
  }
  async waitFor(re, ms = 10000) {
    const t0 = Date.now();
    while (Date.now() - t0 < ms) {
      if (re.test(this.out)) return;
      await sleep(40);
    }
    throw new Error(`timeout waiting for ${re}\n--- last output ---\n${this.out.slice(-3000)}`);
  }
  send(s) { this.p.stdin.write(s + "\n"); }
  async waitExit(ms = 25000) {
    const t = setTimeout(() => { try { this.p.kill("SIGKILL"); } catch {} }, ms);
    const c = await this.exitP;
    clearTimeout(t);
    return c;
  }
}

let passed = 0;
const ok = (name) => { passed++; console.log(`  ok: ${name}`); };

async function test1_happyPath() {
  console.log("test 1: happy path");
  const home = mkHome();
  writeAcf(home, 11111);
  fs.writeFileSync(path.join(home, ".cobalt", "last_install"),
    JSON.stringify({ framework: "carbon", version: "v1.2.3", artifact: "" }));
  fs.writeFileSync(path.join(home, "unity.log"), "OLDLOG-MARKER\n"); // rotation check

  const r = new Run(home);
  await r.waitFor(/Server startup complete/);
  ok("read channel (tail) delivers the done-string");
  assert(!r.out.includes("OLDLOG-MARKER"), "rotated log leaked into console");
  assert(fs.readFileSync(path.join(home, "unity.log.prev"), "utf8").includes("OLDLOG-MARKER"));
  ok("unity.log rotated to .prev at boot");
  await r.waitFor(/\[oxide\]/);
  ok("[oxide] line tagging");
  await r.waitFor(/\[rcon\] connected/);
  ok("WebRCON connected (native WebSocket vs RFC6455 server)");

  const cat = JSON.parse(fs.readFileSync(path.join(home, ".cobalt", "versions.json"), "utf8"));
  assert.equal(cat[0].buildid, 11111);
  assert.equal(cat[0].framework, "carbon");
  assert.equal(cat[0].depots[0].manifest, "7777777777");
  ok("catalog recorded from acf + last_install");

  r.send("status");
  await r.waitFor(/\[rcon\] hostname: mock-rust/);
  await r.waitFor(/\[rcon\] players : 0/);
  ok("matched rcon response printed (multi-line)");

  await sleep(900); // broadcasts flow every 250ms
  assert(!r.out.includes("SPAMLINE"), "unsolicited broadcast leaked to console");
  ok("unsolicited broadcasts suppressed (no dup stream)");

  r.send(".pin");
  await r.waitFor(/pinned to build 11111/);
  assert.equal(fs.readFileSync(path.join(home, ".cobalt", "pin"), "utf8"), "11111");
  ok(".pin writes current buildid");
  r.send(".unpin");
  await r.waitFor(/unpinned/);
  assert(!fs.existsSync(path.join(home, ".cobalt", "pin")));
  ok(".unpin removes pin");

  r.send(".version");
  await r.waitFor(/installed build: 11111 .* carbon v1\.2\.3/);
  ok(".version shows build/framework/pin state");

  r.send(".rollback 424242");
  await r.waitFor(/no catalog entry for '424242'/);
  ok(".rollback rejects unknown build");

  r.send(".stdin say hi");
  await r.waitFor(/\[stdin\] disabled/);
  ok(".stdin gated behind ALLOW_STDIN");

  r.send("!echo hello-from-shell");
  await r.waitFor(/hello-from-shell/);
  ok("! shell passthrough");

  r.send(".help");
  await r.waitFor(/commands:/);
  ok(".help");

  r.send("quit");
  await r.waitFor(/stopping \(stop command\) — quit via rcon/);
  const code = await r.waitExit();
  assert.equal(code, 0);
  assert(/server exited with code 0/.test(r.out));
  ok("graceful quit via rcon, exit 0 propagated");
}

async function test2_stdinFallback() {
  console.log("test 2: rcon down -> stdin quit fallback");
  const home = mkHome();
  writeAcf(home, 11111);
  const r = new Run(home, { pass: "wrongpass" }); // mock rejects; rcon never connects
  await r.waitFor(/Server startup complete/);
  r.send("quit");
  await r.waitFor(/quit via stdin/);
  const code = await r.waitExit();
  assert.equal(code, 0);
  ok("stdin quit fallback works when rcon is down");
}

async function test3_escalation() {
  console.log("test 3: quit ignored -> SIGTERM escalation");
  const home = mkHome();
  writeAcf(home, 11111);
  const r = new Run(home, { envExtra: { SHUTDOWN_TIMEOUT_SEC: "2" }, mockArgs: ["--ignore-quit"] });
  await r.waitFor(/\[rcon\] connected/);
  r.send("quit");
  await r.waitFor(/no exit after 2s — SIGTERM/, 15000);
  await r.waitExit();
  ok("SHUTDOWN_TIMEOUT escalation fires SIGTERM");
}

async function test4_rollbackStaging() {
  console.log("test 4: .rollback staging via fake steamcmd");
  const home = mkHome();
  writeAcf(home, 11111);
  fs.writeFileSync(path.join(home, ".cobalt", "versions.json"), JSON.stringify([{
    buildid: 10000,
    depots: [{ id: "258551", manifest: "1111111111" }],
    framework: "carbon", frameworkVersion: "v1.0.0", frameworkArtifact: "",
    recorded_at: "2026-07-01T00:00:00.000Z",
  }]));
  const r = new Run(home, { envExtra: { COBALT_STEAMCMD: FAKE_STEAMCMD } });
  await r.waitFor(/\[rcon\] connected/);
  r.send(".rollback 10000");
  await r.waitFor(/staged \+ pinned to 10000/, 15000);
  const pending = JSON.parse(fs.readFileSync(path.join(home, ".cobalt", "pending_rollback"), "utf8"));
  assert.equal(pending.buildid, 10000);
  assert.equal(fs.readFileSync(path.join(home, ".cobalt", "pin"), "utf8"), "10000");
  const marker = path.join(home, "steamcmd", "steamapps", "content", "app_258550", "depot_258551",
    "RustDedicated_Data", "rolled-back-1111111111.marker");
  assert(fs.existsSync(marker), "fake depot content missing");
  ok(".rollback downloads depots, stages pending_rollback, pins target");

  r.send(".rollback last");
  await r.waitFor(/already staging|staged \+ pinned/, 8000).catch(() => {});
  r.send("quit");
  await r.waitExit();
  ok("rollback run shuts down cleanly");
}

async function test5_colours() {
  console.log("test 5: console colours (ANSI on when NO_COLOR unset)");
  const home = mkHome();
  writeAcf(home, 11111);
  const r = new Run(home, { color: true });
  await r.waitFor(/Loading extension Oxide/);
  await sleep(200);
  assert(/\x1b\[35m/.test(r.out), "expected magenta ([oxide]) ANSI in coloured output");
  assert(/\x1b\[/.test(r.out), "expected ANSI colour codes when NO_COLOR unset");
  ok("ANSI colours emitted (oxide=magenta) with colour enabled");
  r.send("quit");
  await r.waitExit();
}

async function test6_reconnectAfterDelay() {
  console.log("test 6: connects after RCON is initially down (the Linux undici bug)");
  const home = mkHome();
  writeAcf(home, 11111);
  const r = new Run(home, { mockArgs: ["--rcon-delay", "2500"] }); // RCON binds 2.5s late
  await r.waitFor(/\[rcon\] connecting to/);
  await r.waitFor(/Server startup complete/);
  r.send("status"); // sent while RCON is still down
  await r.waitFor(/not connected yet — command queued/);
  ok("command queued while RCON down");
  await r.waitFor(/\[rcon\] connected/, 12000); // must reconnect after the delay
  ok("wrapper reconnects once RCON comes up (retry loop is event-quirk-proof)");
  await r.waitFor(/\[rcon\] hostname: mock-rust/, 8000); // queued status flushes
  ok("queued command flushed on connect");
  r.send("quit");
  await r.waitExit();
}

async function test7_carbonDoorstop() {
  console.log("test 7: Carbon doorstop env injected into the game child only");
  const home = mkHome();
  writeAcf(home, 11111);
  const r = new Run(home, { envExtra: {
    COBALT_DOORSTOP_TARGET: "/x/carbon/managed/Carbon.Preloader.dll",
    COBALT_DOORSTOP_PRELOAD: "/x/libdoorstop.so",
    COBALT_DOORSTOP_LDPATH: "/x:/x/RustDedicated_Data/Plugins/x86_64",
  } });
  await r.waitFor(/DOORSTOP_ENABLED=1/);
  ok("game child sees DOORSTOP_ENABLED=1");
  assert(r.out.includes("LD_PRELOAD=/x/libdoorstop.so"), "child missing LD_PRELOAD");
  ok("game child sees LD_PRELOAD=libdoorstop.so");
  assert(r.out.includes("TARGET=/x/carbon/managed/Carbon.Preloader.dll"), "child missing DOORSTOP_TARGET_ASSEMBLY");
  ok("game child sees DOORSTOP_TARGET_ASSEMBLY");
  r.send("quit");
  await r.waitExit();
}

async function test8_customColours() {
  console.log("test 8: CONSOLE_COLORS custom hex palette");
  // positional: slot 4 = oxide = ff00ff -> truecolor
  let home = mkHome(); writeAcf(home, 11111);
  let r = new Run(home, { color: true, envExtra: { CONSOLE_COLORS: "00cc66,ff0000,ffcc00,ff00ff,00ffff,00ffff" } });
  await r.waitFor(/Loading extension Oxide/);
  await sleep(150);
  assert(r.out.includes("\x1b[38;2;255;0;255m"), "expected truecolor oxide from positional hex ff00ff");
  ok("positional hex applied (oxide=ff00ff -> 38;2;255;0;255)");
  r.send("quit"); await r.waitExit();
  // named: oxide=00ff00 -> truecolor green
  home = mkHome(); writeAcf(home, 11111);
  r = new Run(home, { color: true, envExtra: { CONSOLE_COLORS: "oxide=00ff00" } });
  await r.waitFor(/Loading extension Oxide/);
  await sleep(150);
  assert(r.out.includes("\x1b[38;2;0;255;0m"), "expected truecolor oxide from named hex 00ff00");
  ok("named hex applied (oxide=00ff00 -> 38;2;0;255;0)");
  r.send("quit"); await r.waitExit();
}

(async () => {
  await test1_happyPath();
  await test2_stdinFallback();
  await test3_escalation();
  await test4_rollbackStaging();
  await test5_colours();
  await test6_reconnectAfterDelay();
  await test7_carbonDoorstop();
  await test8_customColours();
  console.log(`\nE2E: all ${passed} checks passed`);
})().catch((e) => { console.error("\nE2E FAILED:", e.message); process.exit(1); });
