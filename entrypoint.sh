#!/bin/bash
set -euo pipefail

# =======================================================================
# Rust Dedicated Server entrypoint for Pterodactyl (argv-safe)
# - Framework install toggle (FRAMEWORK_UPDATE), Steam validate (VALIDATE)
# - Optional CustomFrameworkURL artifact install
# - Crash auto-restart with rate limiting & backoff
# - CPU-only stall watchdog (utime+stime ticks idle => TERM=>KILL)
# - RCON shutdown commands + local shell shutdown commands
# =======================================================================

export HOME=/home/container
cd /home/container || exit 1

log() { echo -e "[entrypoint] $*"; }
err() { echo -e "[entrypoint][error] $*" >&2; }

# niceties
ulimit -n 65535 || true
umask 002
chown -R "$(id -u):$(id -g)" /home/container 2>/dev/null || true

# -----------------------------------------------------------------------
# SteamCMD layout
# -----------------------------------------------------------------------
mkdir -p \
  /home/container/Steam/package \
  /home/container/steamcmd \
  /home/container/.steam/sdk32 \
  /home/container/.steam/sdk64

export STEAMCMDDIR=/home/container/steamcmd

steamcmd_path() {
  if [[ -x "/home/container/steamcmd/steamcmd.sh" ]]; then echo "/home/container/steamcmd/steamcmd.sh"; return; fi
  if command -v steamcmd >/dev/null 2>&1; then command -v steamcmd; return; fi
  echo ""
}

# -----------------------------------------------------------------------
# Config from panel
# -----------------------------------------------------------------------
SRCDS_APPID="${SRCDS_APPID:-258550}"

STEAM_USER="${STEAM_USER:-anonymous}"
STEAM_PASS="${STEAM_PASS:-}"
STEAM_AUTH="${STEAM_AUTH:-}"

FRAMEWORK="${FRAMEWORK:-vanilla}"          # vanilla | oxide | carbon* (edge/staging/auxX, *-minimal)
FRAMEWORK_UPDATE="${FRAMEWORK_UPDATE:-1}"  # 1=install/update framework, 0=skip
VALIDATE="${VALIDATE:-1}"                  # 1=steamcmd validate, 0=skip

EXTRA_FLAGS="${EXTRA_FLAGS:-}"
STEAM_BRANCH="${STEAM_BRANCH:-}"
STEAM_BRANCH_PASS="${STEAM_BRANCH_PASS:-}"

# Custom framework artifact URL (either name)
CUSTOM_FRAMEWORK_URL="${CUSTOM_FRAMEWORK_URL:-${CustomFrameworkURL:-}}"

# Wrapper log destination
export LATEST_LOG="${LATEST_LOG:-/home/container/latest.log}"

# Watchdog (crash/restart)
WATCHDOG_ENABLED="${WATCHDOG_ENABLED:-1}"
WATCHDOG_MAX_RESTARTS="${WATCHDOG_MAX_RESTARTS:-5}"
WATCHDOG_WINDOW_SEC="${WATCHDOG_WINDOW_SEC:-300}"
WATCHDOG_MIN_UPTIME_SEC="${WATCHDOG_MIN_UPTIME_SEC:-60}"
WATCHDOG_BACKOFF_SEC="${WATCHDOG_BACKOFF_SEC:-5}"

# CPU-only stall detector
STALL_WATCH_ENABLED="${STALL_WATCH_ENABLED:-1}"
WATCHDOG_IDLE_SEC="${WATCHDOG_IDLE_SEC:-120}"
WATCHDOG_CHECK_EVERY="${WATCHDOG_CHECK_EVERY:-10}"
WATCHDOG_GRACE_SEC="${WATCHDOG_GRACE_SEC:-20}"

# Shutdown shell commands (CSV)
SHUTDOWN_CMDS="${SHUTDOWN_CMDS:-}"
SHUTDOWN_CMD_TIMEOUT="${SHUTDOWN_CMD_TIMEOUT:-30}"

# Shutdown RCON commands (CSV) + RCON connection params
SHUTDOWN_RCON_CMDS="${SHUTDOWN_RCON_CMDS:-}"
RCON_HOST="${RCON_HOST:-127.0.0.1}"
RCON_TIMEOUT_SEC="${RCON_TIMEOUT_SEC:-5}"

# optional convenience IP (panel can override)
if [[ -z "${APP_PUBLIC_IP:-}" ]]; then
  APP_PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  export APP_PUBLIC_IP
fi

# -----------------------------------------------------------------------
# Update / validate helpers
# -----------------------------------------------------------------------
do_validate() {
  [[ "${VALIDATE}" != "1" ]] && { log "VALIDATE=0 → skipping SteamCMD validation."; return 0; }

  local SCMD; SCMD="$(steamcmd_path)"
  [[ -z "$SCMD" ]] && { err "steamcmd not found"; exit 11; }

  local BRANCH_FLAGS=""
  [[ -n "$STEAM_BRANCH" ]] && BRANCH_FLAGS="-beta ${STEAM_BRANCH}"
  [[ -n "$STEAM_BRANCH_PASS" ]] && BRANCH_FLAGS="${BRANCH_FLAGS} -betapassword ${STEAM_BRANCH_PASS}"

  log "Validating game files via SteamCMD…"
  "$SCMD" +force_install_dir /home/container \
         +login "${STEAM_USER}" "${STEAM_PASS}" "${STEAM_AUTH}" \
         +app_update "${SRCDS_APPID}" ${BRANCH_FLAGS} ${EXTRA_FLAGS} validate \
         +quit
  log "[  OK  ] validation complete"
}

install_oxide() {
  log "Installing / updating Oxide (uMod)…"
  local tmp; tmp="$(mktemp -d)"
  pushd "$tmp" >/dev/null
  curl -fSL --retry 5 -o oxide.zip "https://umod.org/games/rust/download?build=linux"
  unzip -o -q oxide.zip -d /home/container
  popd >/dev/null
  rm -rf "$tmp"
  log "uMod install complete."
}

install_carbon() {
  log "Installing / updating Carbon…"
  local channel="production" minimal="0" url=""
  case "${FRAMEWORK}" in
    carbon-edge* )    channel="edge" ;;
    carbon-staging* ) channel="staging" ;;
    carbon-aux1* )    channel="aux1" ;;
    carbon-aux2* )    channel="aux2" ;;
    carbon* )         channel="production" ;;
  esac
  [[ "${FRAMEWORK}" == *"-minimal" ]] && minimal="1"

  if [[ "$minimal" == "1" ]]; then
    case "${channel}" in
      production) url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Release.Minimal.tar.gz" ;;
      edge)       url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Edge.Minimal.tar.gz" ;;
      staging)    url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Staging.Minimal.tar.gz" ;;
      aux1)       url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Aux1.Minimal.tar.gz" ;;
      aux2)       url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Aux2.Minimal.tar.gz" ;;
    esac
  else
    case "${channel}" in
      production) url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Release.tar.gz" ;;
      edge)       url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Edge.tar.gz" ;;
      staging)    url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Staging.tar.gz" ;;
      aux1)       url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Aux1.tar.gz" ;;
      aux2)       url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Aux2.tar.gz" ;;
    esac
  fi

  [[ -z "${url}" ]] && { err "Could not determine Carbon artifact for FRAMEWORK='${FRAMEWORK}'"; exit 10; }

  local tmp; tmp="$(mktemp -d)"
  pushd "$tmp" >/dev/null
  curl -fSL --retry 5 -o carbon.tar.gz "${url}"
  tar -xzf carbon.tar.gz -C /home/container
  popd >/dev/null
  rm -rf "$tmp"
  log "Carbon install complete."
}

install_from_custom_url() {
  local url="$1"
  [[ -z "$url" ]] && { err "Custom framework URL is empty."; return 1; }
  log "Installing / updating from Custom Framework URL: ${url}"
  local tmp; tmp="$(mktemp -d)"
  pushd "$tmp" >/dev/null
  case "$url" in
    *.zip)                         curl -fSL --retry 5 -o artifact.zip "$url"; unzip -o -q artifact.zip -d /home/container ;;
    *.tar.gz|*.tgz|*.tar|*.tar.xz) curl -fSL --retry 5 -o artifact.tar.gz "$url"; tar -xzf artifact.tar.gz -C /home/container ;;
    *)                             curl -fSL --retry 5 -o artifact.tar.gz "$url"; tar -xzf artifact.tar.gz -C /home/container ;;
  esac
  popd >/dev/null
  rm -rf "$tmp"
  log "Custom framework install complete."
}

# -----------------------------------------------------------------------
# Framework actions (guarded by FRAMEWORK_UPDATE)
# -----------------------------------------------------------------------
if [[ "${FRAMEWORK_UPDATE}" == "1" ]]; then
  do_validate
  if [[ -n "${CUSTOM_FRAMEWORK_URL}" ]]; then
    log "FRAMEWORK_UPDATE=1 and CustomFrameworkURL detected → using custom artifact (overrides FRAMEWORK='${FRAMEWORK}')."
    install_from_custom_url "${CUSTOM_FRAMEWORK_URL}"
  else
    case "${FRAMEWORK}" in
      oxide|uMod) install_oxide ;;
      carbon*   ) install_carbon ;;
      vanilla|* ) log "FRAMEWORK='${FRAMEWORK}' → no framework to install (vanilla)." ;;
    esac
  fi
else
  log "FRAMEWORK_UPDATE=0 → skipping framework install/update steps."
  do_validate
fi

# -----------------------------------------------------------------------
# Build argv to pass to wrapper (NO STRING JOINING)
# -----------------------------------------------------------------------
if [[ "$#" -gt 0 ]]; then
  ARGV=( "$@" )
else
  if [[ -z "${STARTUP:-}" ]]; then
    err "No startup provided: neither Start Command args nor STARTUP env found."
    exit 12
  fi
  EXPANDED="$(
    eval "echo \"$(printf '%s' "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')\""
  )"
  eval "set -- ${EXPANDED}"
  ARGV=( "$@" )
fi

# strip accidental /entrypoint.sh
if [[ "${#ARGV[@]}" -gt 0 && "${ARGV[0]}" == "/entrypoint.sh" ]]; then
  ARGV=( "${ARGV[@]:1}" )
fi

# ensure Rust binary exists
if [[ ! -f "./RustDedicated" ]]; then
  err "RustDedicated not found in $(pwd). Did app_update install to /home/container?"
  err "Set VALIDATE=1 (or enable AUTO_UPDATE in your egg) and try again."
  exit 13
fi
[[ -x "./RustDedicated" ]] || chmod +x ./RustDedicated || true

# pick wrapper path
WRAPPER="/wrapper.js"
[[ -f "$WRAPPER" ]] || WRAPPER="/opt/cobalt/wrapper.js"
if [[ ! -f "$WRAPPER" ]]; then
  err "wrapper.js not found at /wrapper.js or /opt/cobalt/wrapper.js"
  exit 14
fi

# -----------------------------------------------------------------------
# CPU-only stall helper
# -----------------------------------------------------------------------
proc_ticks() {
  local pid="$1"
  [[ -r "/proc/${pid}/stat" ]] || { echo 0; return; }
  awk '{print $14+$15}' "/proc/${pid}/stat" 2>/dev/null || echo 0
}

cpu_watchdog() {
  local pid="$1"
  local last_ticks cur_ticks last_ts now_ts idle

  last_ticks="$(proc_ticks "${pid}")"
  last_ts="$(date +%s)"

  echo "[watchdog] cpu-only: watching pid ${pid}, idle=${WATCHDOG_IDLE_SEC}s, interval=${WATCHDOG_CHECK_EVERY}s"
  trap 'exit 0' TERM INT

  while kill -0 "${pid}" 2>/dev/null; do
    sleep "${WATCHDOG_CHECK_EVERY}"
    cur_ticks="$(proc_ticks "${pid}")"

    if [[ "${cur_ticks}" != "${last_ticks}" && "${cur_ticks}" != "0" ]]; then
      last_ticks="${cur_ticks}"
      last_ts="$(date +%s)"
      continue
    fi

    now_ts="$(date +%s)"
    idle=$(( now_ts - last_ts ))
    if (( idle >= WATCHDOG_IDLE_SEC )); then
      echo "[watchdog][error] stall detected: no CPU progress for ${idle}s (>= ${WATCHDOG_IDLE_SEC}s). sending SIGTERM to ${pid}…"
      kill -TERM "${pid}" 2>/dev/null || true

      for (( i=0; i<WATCHDOG_GRACE_SEC; i++ )); do
        sleep 1
        kill -0 "${pid}" 2>/dev/null || { echo "[watchdog] process exited after TERM"; exit 0; }
      done

      echo "[watchdog][error] still running after ${WATCHDOG_GRACE_SEC}s → SIGKILL ${pid}"
      kill -KILL "${pid}" 2>/dev/null || true
      exit 0
    fi
  done

  echo "[watchdog] target pid ended; exiting cpu watchdog"
  exit 0
}

# -----------------------------------------------------------------------
# RCON helper (inline Node, Source RCON TCP)
# -----------------------------------------------------------------------
send_rcon_cmds() {
  local cmds_csv="$1"
  [[ -z "${cmds_csv// }" ]] && return 0
  [[ -z "${RCON_PORT:-}" || -z "${RCON_PASS:-}" ]] && { err "RCON not configured (RCON_PORT/RCON_PASS). Skipping RCON shutdown cmds."; return 1; }

  /opt/node/bin/node - <<'__RCON_JS__' || return $?
const net = require('net');

const HOST = process.env.RCON_HOST || '127.0.0.1';
const PORT = parseInt(process.env.RCON_PORT || '28016', 10);
const PASS = process.env.RCON_PASS || '';
const TIMEOUT_MS = (parseInt(process.env.RCON_TIMEOUT_SEC || '5', 10) * 1000) || 5000;
const CMDS = (process.env.SHUTDOWN_RCON_CMDS || '').split(',').map(s => s.trim()).filter(Boolean);

const SERVERDATA_AUTH = 3;
const SERVERDATA_EXECCOMMAND = 2;

let reqId = 1;

function pkt(id, type, body) {
  const bodyBuf = Buffer.from(body, 'utf8');
  const len = 4 + 4 + bodyBuf.length + 2;
  const buf = Buffer.alloc(4 + len);
  buf.writeInt32LE(len, 0);
  buf.writeInt32LE(id, 4);
  buf.writeInt32LE(type, 8);
  bodyBuf.copy(buf, 12);
  buf.writeInt8(0, 12 + bodyBuf.length);
  buf.writeInt8(0, 13 + bodyBuf.length);
  return buf;
}

function readPackets(buffer) {
  const packets = [];
  let offset = 0;
  while (buffer.length - offset >= 4) {
    const plen = buffer.readInt32LE(offset);
    if (plen < 10) break;
    if (buffer.length - offset - 4 < plen) break;
    const start = offset + 4;
    const id = buffer.readInt32LE(start);
    const type = buffer.readInt32LE(start + 4);
    const bodyEnd = start + 8 + (plen - 10);
    const body = buffer.toString('utf8', start + 8, bodyEnd);
    packets.push({ id, type, body });
    offset += 4 + plen;
  }
  return { packets, remaining: buffer.slice(offset) };
}

function connectRcon() {
  return new Promise((resolve, reject) => {
    const sock = net.createConnection({ host: HOST, port: PORT }, () => resolve(sock));
    sock.setTimeout(TIMEOUT_MS, () => { sock.destroy(new Error('timeout')); });
    sock.on('error', reject);
  });
}

async function auth(sock) {
  return new Promise((resolve, reject) => {
    const id = reqId++;
    sock.write(pkt(id, SERVERDATA_AUTH, PASS));

    let buf = Buffer.alloc(0);
    const onData = (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      const { packets, remaining } = readPackets(buf);
      buf = remaining;
      for (const p of packets) {
        if (p.id === id || p.id === -1) {
          sock.off('data', onData);
          if (p.id === -1) return reject(new Error('auth failed'));
          return resolve();
        }
      }
    };
    sock.on('data', onData);
    sock.once('error', reject);
  });
}

async function exec(sock, cmd) {
  return new Promise((resolve) => {
    const id = reqId++;
    sock.write(pkt(id, SERVERDATA_EXECCOMMAND, cmd));
    const onData = () => { /* ignore responses */ };
    sock.once('data', onData);
    setTimeout(() => {
      sock.off('data', onData);
      resolve();
    }, 200);
  });
}

(async () => {
  if (CMDS.length === 0) process.exit(0);

  const sock = await connectRcon().catch(e => { console.error('[rcon] connect failed:', e.message); process.exit(2); });
  try {
    await auth(sock);
  } catch (e) {
    console.error('[rcon] auth failed:', e.message);
    sock.destroy();
    process.exit(3);
  }

  for (const c of CMDS) {
    try {
      console.log('[rcon] cmd:', c);
      await exec(sock, c);
    } catch (e) {
      console.error('[rcon] cmd error:', e.message);
    }
  }

  try { sock.end(); } catch {}
  setTimeout(() => process.exit(0), 50);
})();
__RCON_JS__
}

# -----------------------------------------------------------------------
# Shutdown commands helper
# -----------------------------------------------------------------------
shutdown_ran="0"
run_shutdown_cmds() {
  [[ "${shutdown_ran}" == "1" ]] && return 0
  shutdown_ran="1"

  # 1) Send RCON commands first (save, broadcast, etc.)
  if [[ -n "${SHUTDOWN_RCON_CMDS// }" ]]; then
    log "Sending shutdown RCON commands: ${SHUTDOWN_RCON_CMDS}"
    if ! send_rcon_cmds "${SHUTDOWN_RCON_CMDS}"; then
      err "Failed to send one or more RCON shutdown commands."
    fi
    sleep 1
  else
    log "No shutdown RCON commands configured."
  fi

  # 2) Run local shutdown shell commands (CSV)
  if [[ -z "${SHUTDOWN_CMDS// }" ]]; then
    log "No local shutdown shell commands configured."
    return 0
  fi

  log "Running local shutdown shell commands…"
  local IFS=','; read -r -a CMDS <<< "${SHUTDOWN_CMDS}"
  for raw in "${CMDS[@]}"; do
    cmd="${raw#"${raw%%[![:space:]]*}"}"; cmd="${cmd%"${cmd##*[![:space:]]}"}"
    [[ -z "${cmd}" ]] && continue
    log "shutdown: ${cmd}"
    if ! timeout "${SHUTDOWN_CMD_TIMEOUT}" bash -lc "${cmd}"; then
      err "shutdown command failed or timed out (${SHUTDOWN_CMD_TIMEOUT}s): ${cmd}"
    fi
  done
  log "Shutdown commands complete."
}

# -----------------------------------------------------------------------
# Crash watchdog main loop (spawns CPU watchdog per run)
# -----------------------------------------------------------------------
child_pid=""
term_requested="0"

forward_signal() {
  local sig="$1"
  if [[ -n "${child_pid}" ]]; then
    log "Forwarding ${sig} to child PID ${child_pid}"
    kill "-${sig}" "${child_pid}" 2>/dev/null || true
  fi
}

trap 'term_requested="1"; forward_signal TERM' TERM
trap 'term_requested="1"; forward_signal INT'  INT

restart_timestamps=()  # epoch seconds

within_window_count() {
  local now cutoff keep=()
  now="$(date +%s)"; cutoff=$(( now - WATCHDOG_WINDOW_SEC ))
  for t in "${restart_timestamps[@]:-}"; do
    if (( t >= cutoff )); then keep+=( "$t" ); fi
  done
  restart_timestamps=( "${keep[@]}" )
  echo "${#restart_timestamps[@]}"
}

should_restart() {
  local rc="$1" uptime="$2"

  # graceful stop
  if [[ "${rc}" -eq 0 ]]; then
    log "Server exited cleanly (rc=0). Not restarting."
    return 1
  fi

  if [[ "${WATCHDOG_ENABLED}" != "1" ]]; then
    log "WATCHDOG_ENABLED=0 → not restarting (rc=${rc})."
    return 1
  fi

  if (( uptime < WATCHDOG_MIN_UPTIME_SEC )); then
    log "Detected crash (rc=${rc}, uptime=${uptime}s < ${WATCHDOG_MIN_UPTIME_SEC}s)."
    return 0
  fi

  log "Unexpected exit (rc=${rc}, uptime=${uptime}s). Attempting restart."
  return 0
}

log "Launching via wrapper (argv mode)…"
while :; do
  start_ts="$(date +%s)"

  # Spawn WITHOUT exec so we can supervise & restart
  /opt/node/bin/node "$WRAPPER" --argv "${ARGV[@]}" &
  child_pid="$!"

  # Start CPU-only stall watcher for this run
  if [[ "${STALL_WATCH_ENABLED}" == "1" ]]; then
    cpu_watchdog "${child_pid}" &
    stall_pid="$!"
  fi

  # Wait for server to exit; capture rc
  rc=0
  wait "${child_pid}" || rc=$?

  # Stop the stall watcher
  [[ -n "${stall_pid:-}" ]] && kill -TERM "${stall_pid}" 2>/dev/null || true
  unset stall_pid

  end_ts="$(date +%s)"
  uptime=$(( end_ts - start_ts ))

  # If we won't restart (graceful or watchdog disabled), run shutdown cmds once and exit
  if ! should_restart "${rc}" "${uptime}"; then
    run_shutdown_cmds
    exit "${rc}"
  fi

  # Rate limiting
  now_ts="$(date +%s)"
  restart_timestamps+=( "${now_ts}" )
  count="$(within_window_count)"

  if (( count > WATCHDOG_MAX_RESTARTS )); then
    err "Watchdog: exceeded ${WATCHDOG_MAX_RESTARTS} restarts within ${WATCHDOG_WINDOW_SEC}s. Stopping."
    run_shutdown_cmds
    exit "${rc}"
  fi

  # If a termination was requested (panel stop), do not loop; run shutdown commands.
  if [[ "${term_requested}" == "1" ]]; then
    log "Termination requested by panel. Not restarting."
    run_shutdown_cmds
    exit "${rc}"
  fi

  log "Watchdog sleeping ${WATCHDOG_BACKOFF_SEC}s before restart (restart #${count}/${WATCHDOG_MAX_RESTARTS})."
  sleep "${WATCHDOG_BACKOFF_SEC}"
  log "Watchdog restarting server…"
done
