#!/bin/bash
set -euo pipefail

RED='\e[31m'; YEL='\e[33m'; GRN='\e[32m'; NC='\e[0m'

export HOME=/home/container
cd /home/container || exit 1

log()  { echo -e "[entrypoint] $*"; }
warn() { echo -e "${YEL}[warn]${NC} $*"; }
bad()  { echo -e "${RED}[ERROR]${NC} $*"; }
good() { echo -e "${GRN}[ok]${NC} $*"; }

# niceties
ulimit -n 65535 || true
umask 002
chown -R "$(id -u):$(id -g)" /home/container 2>/dev/null || true

# SteamCMD layout
mkdir -p /home/container/Steam/package /home/container/steamcmd /home/container/.steam/sdk32 /home/container/.steam/sdk64
export STEAMCMDDIR=/home/container/steamcmd

steamcmd_path() {
  if [[ -x "/home/container/steamcmd/steamcmd.sh" ]]; then echo "/home/container/steamcmd/steamcmd.sh"; return; fi
  if command -v steamcmd >/dev/null 2>&1; then command -v steamcmd; return; fi
  echo ""
}

# -------- Panel config --------
SRCDS_APPID="${SRCDS_APPID:-258550}"

STEAM_USER="${STEAM_USER:-anonymous}"
STEAM_PASS="${STEAM_PASS:-}"
STEAM_AUTH="${STEAM_AUTH:-}"

FRAMEWORK="${FRAMEWORK:-vanilla}"
FRAMEWORK_UPDATE="${FRAMEWORK_UPDATE:-1}"
VALIDATE="${VALIDATE:-1}"

EXTRA_FLAGS="${EXTRA_FLAGS:-}"
STEAM_BRANCH="${STEAM_BRANCH:-}"
STEAM_BRANCH_PASS="${STEAM_BRANCH_PASS:-}"

DEFAULT_STEAM_BRANCH=""
case "${FRAMEWORK}" in
  vanilla-staging|oxide-staging|carbon-staging* ) DEFAULT_STEAM_BRANCH="staging" ;;
  vanilla-aux1|carbon-aux1* )                     DEFAULT_STEAM_BRANCH="aux1" ;;
  vanilla-aux2|carbon-aux2* )                     DEFAULT_STEAM_BRANCH="aux2" ;;
  * )                                             DEFAULT_STEAM_BRANCH="" ;;
esac

CUSTOM_FRAMEWORK_URL="${CUSTOM_FRAMEWORK_URL:-${CustomFrameworkURL:-}}"

export LATEST_LOG="${LATEST_LOG:-/home/container/latest.log}"

# Ping-based supervision (watcher starts only after ready token)
WATCH_ENABLED="${WATCH_ENABLED:-1}"
HEARTBEAT_TIMEOUT_SEC="${HEARTBEAT_TIMEOUT_SEC:-120}"
WATCH_CHECK_SEC="${WATCH_CHECK_SEC:-10}"

# Optional convenience IP
if [[ -z "${APP_PUBLIC_IP:-}" ]]; then
  APP_PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  export APP_PUBLIC_IP
fi

# Shutdown (single timeout)
SHUTDOWN_CMDS="${SHUTDOWN_CMDS:-}"
SHUTDOWN_RCON_CMDS="${SHUTDOWN_RCON_CMDS:-}"
SHUTDOWN_TIMEOUT_SEC="${SHUTDOWN_TIMEOUT_SEC:-30}"
RCON_HOST="${RCON_HOST:-127.0.0.1}"

# Disk & limits awareness (hidden defaults)
DISK_MIN_FREE_MB="${DISK_MIN_FREE_MB:-1024}"
DISK_ENFORCE="${DISK_ENFORCE:-0}" # warn only
HEAP_TARGET_MB="${HEAP_TARGET_MB:-}"

# OOM detector (hidden default)
OOM_WATCH="${OOM_WATCH:-1}"
OOM_STATE_FILE="/home/container/.oom_seen"

# Wipe planner
WIPE_ENABLE="${WIPE_ENABLE:-0}"
WIPE_CRON="${WIPE_CRON:-}"
WIPE_RCON_CMDS="${WIPE_RCON_CMDS:-global.say \"Wipe in progress\",save.all,quit}"
NEXT_WORLD_SIZE="${NEXT_WORLD_SIZE:-}"
NEXT_WORLD_SEED="${NEXT_WORLD_SEED:-}"
NEXT_OVERRIDES_FILE="/home/container/.next_world.env"

# Crash bundles
CRASH_ARCHIVE="${CRASH_ARCHIVE:-1}"
CRASH_PATH="${CRASH_PATH:-/crashdumps}"

# Preflight port checks
PREFLIGHT_PORTCHECK="${PREFLIGHT_PORTCHECK:-1}"

# Startup token (kept as hidden var in egg)
STARTUP_DONE_TOKEN="${STARTUP_DONE_TOKEN:-Server startup complete}"

# -------- Limits awareness (red warnings) --------
cgroup_mem_limit_mb() {
  local lim
  if [[ -r /sys/fs/cgroup/memory.max ]]; then
    lim=$(cat /sys/fs/cgroup/memory.max)
    [[ "$lim" == "max" ]] && { echo 0; return; }
    echo $(( lim/1024/1024 ))
  elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
    lim=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
    echo $(( lim/1024/1024 ))
  else
    echo 0
  fi
}
cgroup_cpu_quota() {
  if [[ -r /sys/fs/cgroup/cpu.max ]]; then
    awk '{ if ($1=="max") {print "unlimited"} else {printf("%.2f", $1/$2)} }' /sys/fs/cgroup/cpu.max
  elif [[ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us && -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]]; then
    local q=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
    local p=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
    if (( q < 0 )); then echo "unlimited"; else awk -v q="$q" -v p="$p" 'BEGIN{printf("%.2f", q/p)}'; fi
  else
    echo "unknown"
  fi
}
MEM_LIMIT_MB=$(cgroup_mem_limit_mb)
CPU_LIMIT_CORES=$(cgroup_cpu_quota)
log "Container limits: memory=${MEM_LIMIT_MB:-0}MB cpu=${CPU_LIMIT_CORES}"
if [[ -n "$HEAP_TARGET_MB" && "$MEM_LIMIT_MB" -gt 0 && "$HEAP_TARGET_MB" -gt "$MEM_LIMIT_MB" ]]; then
  echo -e "${RED}[LIMIT] HEAP_TARGET_MB=${HEAP_TARGET_MB}MB exceeds container memory limit ${MEM_LIMIT_MB}MB — expect OOM!${NC}"
fi
if [[ "$MEM_LIMIT_MB" -gt 0 && "$MEM_LIMIT_MB" -lt 4096 ]]; then
  echo -e "${RED}[LIMIT] Low container memory (${MEM_LIMIT_MB}MB). Consider 6–8 GB for modded servers.${NC}"
fi

# -------- Disk-space guard (warn only) --------
free_mb=$(df -Pm /home/container | awk 'NR==2{print $4}')
if (( free_mb < DISK_MIN_FREE_MB )); then
  echo -e "${RED}[DISK] Free space ${free_mb}MB < threshold ${DISK_MIN_FREE_MB}MB on /home/container${NC}"
  warn "Continuing despite low disk (warn-only)."
else
  good "Disk free ${free_mb}MB ≥ ${DISK_MIN_FREE_MB}MB"
fi

# -------- Preflight port checks --------
check_port() {
  local proto="$1" port="$2"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnup | grep -q ":${port} " && return 1
    [[ "$proto" == "udp" ]] && ss -lunp | grep -q ":${port} " && return 1
    return 0
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tuln | grep -q ":${port} " && return 1
    return 0
  fi
  return 0
}
if [[ "$PREFLIGHT_PORTCHECK" == "1" ]]; then
  fail=0
  for spec in "tcp:${RCON_PORT:-}" "udp:${QUERY_PORT:-}" "udp:${SERVER_PORT:-}"; do
    proto="${spec%%:*}"; port="${spec##*:}"
    [[ -z "$port" ]] && continue
    if ! check_port "$proto" "$port"; then
      echo -e "${RED}[PORT] ${proto^^} port ${port} already in use inside container.${NC}"
      fail=1
    fi
  done
  if (( fail )); then
    bad "Preflight port check failed — fix bindings or change ports."
    exit 61
  fi
fi

# -------- OOM detector --------
oom_read_counter() {
  if [[ -r /sys/fs/cgroup/memory.events ]]; then
    awk '/oom_kill/ {print $2}' /sys/fs/cgroup/memory.events
  elif [[ -r /sys/fs/cgroup/memory/memory.oom_control ]]; then
    echo 0
  else
    echo 0
  fi
}
if [[ "${OOM_WATCH}" == "1" ]]; then
  prev=$(oom_read_counter)
  if [[ -f "$OOM_STATE_FILE" ]]; then
    last=$(cat "$OOM_STATE_FILE" 2>/dev/null || echo 0)
    if (( prev > last )); then
      echo -e "${RED}[OOM] Previous run saw ${prev-last} OOM kill(s). Investigate memory limits/logs.${NC}"
    fi
  fi
  printf "%s" "$prev" > "$OOM_STATE_FILE" || true
  (
    trap 'exit 0' TERM INT
    while :; do
      sleep 5
      cur=$(oom_read_counter)
      if (( cur > prev )); then
        echo -e "${RED}[OOM] Detected OOM kill (${cur-prev} new). Server may crash or become unstable.${NC}"
        prev="$cur"
        printf "%s" "$prev" > "$OOM_STATE_FILE" || true
      fi
    done
  ) &
fi

# -------- Wipe planner (mini cron) --------
match_cron_field() {
  local field="$1" val="$2"
  [[ "$field" == "*" ]] && return 0
  IFS=',' read -ra parts <<< "$field"
  for p in "${parts[@]}"; do
    if [[ "$p" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      [[ "$val" -ge "${BASH_REMATCH[1]}" && "$val" -le "${BASH_REMATCH[2]}" ]] && return 0
    elif [[ "$p" =~ ^\*/([0-9]+)$ ]]; then
      (( val % ${BASH_REMATCH[1]} == 0 )) && return 0
    elif [[ "$p" =~ ^[0-9]+$ ]]; then
      [[ "$val" -eq "$p" ]] && return 0
    fi
  done
  return 1
}
cron_matches_now() {
  local min hour dom mon dow; read -r min hour dom mon dow <<< "$1"
  local nmin nhour ndom nmon ndow
  nmin=$(date +%M); nhour=$(date +%H); ndom=$(date +%d); nmon=$(date +%m); ndow=$(date +%w)
  match_cron_field "$min" "$((10#$nmin))" && \
  match_cron_field "$hour" "$((10#$nhour))" && \
  match_cron_field "$dom" "$((10#$ndom))" && \
  match_cron_field "$mon" "$((10#$nmon))" && \
  match_cron_field "$dow" "$((10#$ndow))"
}
trigger_wipe() {
  echo -e "${YEL}[wipe] Triggering wipe via RCON & quit…${NC}"
  SHUTDOWN_RCON_CMDS="${WIPE_RCON_CMDS}" send_rcon_cmds "${WIPE_RCON_CMDS}" || warn "Wipe RCON cmds may have failed."
  if [[ -n "$NEXT_WORLD_SIZE" || -n "$NEXT_WORLD_SEED" ]]; then
    {
      [[ -n "$NEXT_WORLD_SIZE" ]] && echo "WORLD_SIZE=${NEXT_WORLD_SIZE}"
      [[ -n "$NEXT_WORLD_SEED" ]] && echo "WORLD_SEED=${NEXT_WORLD_SEED}"
    } > "$NEXT_OVERRIDES_FILE"
    log "Next world overrides saved to $(basename "$NEXT_OVERRIDES_FILE")."
  fi
}
if [[ "$WIPE_ENABLE" == "1" && -n "$WIPE_CRON" ]]; then
  (
    trap 'exit 0' TERM INT
    last_min=""
    while :; do
      now_min="$(date +%Y%m%d%H%M)"
      if [[ "$now_min" != "$last_min" ]]; then
        last_min="$now_min"
        if cron_matches_now "$WIPE_CRON"; then
          trigger_wipe
        fi
      fi
      sleep 5
    done
  ) &
fi

# Apply next world overrides if present
if [[ -f "$NEXT_OVERRIDES_FILE" ]]; then
  warn "Applying next world overrides from $(basename "$NEXT_OVERRIDES_FILE")."
  # shellcheck disable=SC1090
  source "$NEXT_OVERRIDES_FILE" || true
  rm -f "$NEXT_OVERRIDES_FILE" || true
fi

# -------- Validate / framework install --------
do_validate() {
  [[ "${VALIDATE}" != "1" ]] && { log "VALIDATE=0 → skipping SteamCMD validation."; return 0; }
  local SCMD; SCMD="$(steamcmd_path)"
  [[ -z "$SCMD" ]] && { bad "steamcmd not found"; exit 11; }
  local RESOLVED_BRANCH="${STEAM_BRANCH:-${DEFAULT_STEAM_BRANCH}}"
  local BRANCH_FLAGS=""
  [[ -n "$RESOLVED_BRANCH" ]] && BRANCH_FLAGS="-beta ${RESOLVED_BRANCH}"
  [[ -n "$STEAM_BRANCH_PASS" ]] && BRANCH_FLAGS="${BRANCH_FLAGS} -betapassword ${STEAM_BRANCH_PASS}"
  log "SteamCMD validate (branch: ${RESOLVED_BRANCH:-default})…"
  "$SCMD" +force_install_dir /home/container +login "${STEAM_USER}" "${STEAM_PASS}" "${STEAM_AUTH}" +app_update "${SRCDS_APPID}" ${BRANCH_FLAGS} ${EXTRA_FLAGS} validate +quit
  good "Steam files validated."
}
install_oxide() {
  log "Installing Oxide (uMod)…"
  local tmp; tmp="$(mktemp -d)"; pushd "$tmp" >/dev/null
  curl -fSL --retry 5 -o oxide.zip "https://umod.org/games/rust/download?build=linux"
  unzip -o -q oxide.zip -d /home/container
  popd >/dev/null; rm -rf "$tmp"; good "uMod install complete."
}
install_carbon() {
  log "Installing Carbon…"
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
    case "$channel" in
      production) url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Release.Minimal.tar.gz" ;;
      edge)       url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Edge.Minimal.tar.gz" ;;
      staging)    url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Staging.Minimal.tar.gz" ;;
      aux1)       url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Aux1.Minimal.tar.gz" ;;
      aux2)       url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Aux2.Minimal.tar.gz" ;;
    esac
  else
    case "$channel" in
      production) url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Release.tar.gz" ;;
      edge)       url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Edge.tar.gz" ;;
      staging)    url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Staging.tar.gz" ;;
      aux1)       url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Aux1.tar.gz" ;;
      aux2)       url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Aux2.tar.gz" ;;
    esac
  fi
  [[ -z "$url" ]] && { bad "Could not determine Carbon artifact"; exit 10; }
  local tmp; tmp="$(mktemp -d)"; pushd "$tmp" >/dev/null
  curl -fSL --retry 5 -o carbon.tar.gz "${url}"
  tar -xzf carbon.tar.gz -C /home/container
  popd >/dev/null; rm -rf "$tmp"; good "Carbon install complete."
}
install_from_custom_url() {
  local url="$1"; [[ -z "$url" ]] && { bad "Custom framework URL empty"; return 1; }
  log "Installing custom framework from URL…"
  local tmp; tmp="$(mktemp -d)"; pushd "$tmp" >/dev/null
  case "$url" in
    *.zip) curl -fSL --retry 5 -o artifact.zip "$url"; unzip -o -q artifact.zip -d /home/container ;;
    *.tar.gz|*.tgz|*.tar|*.tar.xz) curl -fSL --retry 5 -o artifact.tar.gz "$url"; tar -xzf artifact.tar.gz -C /home/container ;;
    *) curl -fSL --retry 5 -o artifact.tar.gz "$url"; tar -xzf artifact.tar.gz -C /home/container ;;
  esac
  popd >/dev/null; rm -rf "$tmp"; good "Custom framework install complete."
}

if [[ "${FRAMEWORK_UPDATE}" == "1" ]]; then
  do_validate
  if [[ -n "${CUSTOM_FRAMEWORK_URL}" ]]; then
    warn "Using custom framework URL (overrides FRAMEWORK)."
    install_from_custom_url "${CUSTOM_FRAMEWORK_URL}"
  else
    case "${FRAMEWORK}" in
      oxide|uMod) install_oxide ;;
      carbon*   ) install_carbon ;;
      *         ) log "Vanilla channel; no framework to install." ;;
    esac
  fi
else
  warn "FRAMEWORK_UPDATE=0 → skipping framework install."
  do_validate
fi

# -------- Build argv --------
if [[ "$#" -gt 0 ]]; then
  ARGV=( "$@" )
else
  [[ -z "${STARTUP:-}" ]] && { bad "No STARTUP provided."; exit 12; }
  EXPANDED="$(eval "echo \"$(printf '%s' "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')\"" )"
  eval "set -- ${EXPANDED}"
  ARGV=( "$@" )
fi
if [[ "${#ARGV[@]}" -gt 0 && "${ARGV[0]}" == "/entrypoint.sh" ]]; then ARGV=( "${ARGV[@]:1}" ); fi

if [[ ! -f "./RustDedicated" ]]; then bad "RustDedicated not found. Enable VALIDATE=1 and retry."; exit 13; fi
[[ -x "./RustDedicated" ]] || chmod +x ./RustDedicated || true

WRAPPER="/wrapper.js"; [[ -f "$WRAPPER" ]] || WRAPPER="/opt/cobalt/wrapper.js"
[[ -f "$WRAPPER" ]] || { bad "wrapper.js not found at /wrapper.js or /opt/cobalt/wrapper.js"; exit 14; }

# -------- Probes: A2S (UDP) + RCON (TCP) --------
probe_a2s() {
  local port="${QUERY_PORT:-}"
  [[ -z "$port" ]] && return 1
  python3 - <<'__A2S__' >/dev/null 2>&1 || return 1
import socket,os,sys
PORT=int(os.environ.get('QUERY_PORT','0') or 0)
if PORT<=0: sys.exit(1)
pkt=b'\xFF\xFF\xFF\xFFTSource Engine Query\x00'
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(1.0)
try:
    s.sendto(pkt, ('127.0.0.1', PORT))
    data,_=s.recvfrom(4096)
    sys.exit(0 if len(data)>=5 and data[:4]==b'\xFF\xFF\xFF\xFF' and data[4:5]==b'I' else 1)
except Exception:
    sys.exit(1)
finally:
    s.close()
__A2S__
}

probe_rcon() {
  [[ -z "${RCON_PORT:-}" || -z "${RCON_PASS:-}" ]] && return 1
  /opt/node/bin/node - <<'__RCON_PING__'
const net = require('net');
const HOST = process.env.RCON_HOST || '127.0.0.1';
const PORT = parseInt(process.env.RCON_PORT || '28016', 10);
const PASS = process.env.RCON_PASS || '';
const TIMEOUT_MS = 2000;
const SERVERDATA_AUTH = 3, SERVERDATA_EXECCOMMAND = 2;
let id = 1;
function pkt(i,t,body){const b=Buffer.from(body,'utf8');const len=4+4+b.length+2;const buf=Buffer.alloc(4+len);
buf.writeInt32LE(len,0);buf.writeInt32LE(i,4);buf.writeInt32LE(t,8);b.copy(buf,12);buf.writeInt8(0,12+b.length);buf.writeInt8(0,13+b.length);return buf;}
(async()=>{
  try{
    const sock = net.createConnection({host:HOST,port:PORT});
    sock.setTimeout(TIMEOUT_MS, ()=>sock.destroy(new Error('timeout')));
    await new Promise((res,rej)=>{sock.once('connect',res); sock.once('error',rej);});
    await new Promise((res,rej)=>{
      const rid=id++; sock.write(pkt(rid, SERVERDATA_AUTH, PASS));
      const to=setTimeout(()=>rej(new Error('auth timeout')), TIMEOUT_MS);
      sock.once('data',(ch)=>{ clearTimeout(to); (ch.readInt32LE(4)===-1)?rej(new Error('auth failed')):res(); });
      sock.once('error',rej);
    });
    sock.write(pkt(id++, SERVERDATA_EXECCOMMAND, 'serverinfo'));
    setTimeout(()=>{ try{sock.end();}catch{} process.exit(0); }, 50);
  }catch{ process.exit(1); }
})();
__RCON_PING__
}

# -------- Wait until ready token appears (hard-enabled) --------
wait_until_ready() {
  echo "[watch] waiting for startup token '${STARTUP_DONE_TOKEN}' before enabling ping watcher…"
  while :; do
    if [[ -n "${LATEST_LOG:-}" && -f "${LATEST_LOG}" ]] && grep -qF -- "${STARTUP_DONE_TOKEN}" "${LATEST_LOG}" 2>/dev/null; then
      echo "[watch] startup token seen; enabling ping watcher."
      return 0
    fi
    sleep 5
  done
}

# -------- Minimal ping-based watcher --------
ping_watch() {
  local pid="$1" last_ok now idle
  last_ok="$(date +%s)"
  echo "[watch] ping mode: A2S + RCON, interval=${WATCH_CHECK_SEC}s, timeout=${HEARTBEAT_TIMEOUT_SEC}s"
  trap 'exit 0' TERM INT
  while kill -0 "${pid}" 2>/dev/null; do
    sleep "${WATCH_CHECK_SEC}"
    if probe_rcon || probe_a2s; then
      last_ok="$(date +%s)"
      continue
    fi
    now="$(date +%s)"; idle=$(( now - last_ok ))
    if (( idle >= HEARTBEAT_TIMEOUT_SEC )); then
      echo -e "${RED}[watch] stall: no successful game ping for ${idle}s (>= ${HEARTBEAT_TIMEOUT_SEC}s). TERM pid ${pid}${NC}"
      kill -TERM "${pid}" 2>/dev/null || true
      for (( i=0; i<20; i++ )); do
        sleep 1
        kill -0 "${pid}" 2>/dev/null || { echo "[watch] process exited after TERM"; exit 0; }
      done
      echo -e "${RED}[watch] still running → KILL pid ${pid}${NC}"
      kill -KILL "${pid}" 2>/dev/null || true
      exit 0
    fi
  done
  exit 0
}

# -------- RCON helper (shutdown/wipe) --------
send_rcon_cmds() {
  local cmds_csv="$1"
  [[ -z "${cmds_csv// }" ]] && return 0
  [[ -z "${RCON_PORT:-}" || -z "${RCON_PASS:-}" ]] && { warn "RCON not configured; skipping RCON cmds."; return 1; }
  /opt/node/bin/node - <<'__RCON_JS__' || return $?
const net = require('net');
const HOST = process.env.RCON_HOST || '127.0.0.1';
const PORT = parseInt(process.env.RCON_PORT || '28016', 10);
const PASS = process.env.RCON_PASS || '';
const TIMEOUT_MS = (parseInt(process.env.SHUTDOWN_TIMEOUT_SEC || '30', 10)*1000) || 30000;
const CMDS = (process.env.SHUTDOWN_RCON_CMDS || process.env.WIPE_RCON_CMDS || '').split(',').map(s=>s.trim()).filter(Boolean);
const SERVERDATA_AUTH = 3, SERVERDATA_EXECCOMMAND = 2; let reqId = 1;
function pkt(id, type, body){const b=Buffer.from(body,'utf8');const len=4+4+b.length+2;const buf=Buffer.alloc(4+len);buf.writeInt32LE(len,0);buf.writeInt32LE(id,4);buf.writeInt32LE(type,8);b.copy(buf,12);buf.writeInt8(0,12+b.length);buf.writeInt8(0,13+b.length);return buf;}
(async()=>{
  try{
    const sock = net.createConnection({host:HOST,port:PORT});
    sock.setTimeout(TIMEOUT_MS, ()=>sock.destroy(new Error('timeout')));
    await new Promise((res,rej)=>{sock.once('connect',res); sock.once('error',rej);});
    await new Promise((res,rej)=>{
      const rid=reqId++; sock.write(pkt(rid, SERVERDATA_AUTH, PASS));
      const to=setTimeout(()=>rej(new Error('auth timeout')), TIMEOUT_MS);
      sock.once('data',(ch)=>{ clearTimeout(to); (ch.readInt32LE(4)===-1)?rej(new Error('auth failed')):res(); });
    });
    for (const c of CMDS){ try{ sock.write(pkt(reqId++, SERVERDATA_EXECCOMMAND, c)); } catch{} }
    setTimeout(()=>{ try{sock.end();}catch{} process.exit(0); }, 50);
  }catch{ process.exit(1); }
})();
__RCON_JS__
}

# -------- Shutdown hooks --------
shutdown_ran="0"
run_shutdown_cmds() {
  [[ "${shutdown_ran}" == "1" ]] && return 0
  shutdown_ran="1"
  if [[ -n "${SHUTDOWN_RCON_CMDS// }" ]]; then
    log "Sending shutdown RCON commands: ${SHUTDOWN_RCON_CMDS}"
    send_rcon_cmds "${SHUTDOWN_RCON_CMDS}" || warn "Some RCON shutdown commands may have failed."
    sleep 1
  fi
  if [[ -n "${SHUTDOWN_CMDS// }" ]]; then
    log "Running local shutdown shell commands…"
    local IFS=','; read -r -a CMDS <<< "${SHUTDOWN_CMDS}"
    for raw in "${CMDS[@]}"; do
      cmd="${raw#"${raw%%[![:space:]]*}"}"; cmd="${cmd%"${cmd##*[![:space:]]}"}"
      [[ -z "${cmd}" ]] && continue
      log "shutdown: ${cmd}"
      timeout "${SHUTDOWN_TIMEOUT_SEC}" bash -lc "${cmd}" || warn "shutdown command failed or timed out (${SHUTDOWN_TIMEOUT_SEC}s): ${cmd}"
    done
  fi
}

# -------- Crash bundles --------
make_crash_bundle() {
  [[ "${CRASH_ARCHIVE}" != "1" ]] && return 0
  mkdir -p "${CRASH_PATH}"
  ts="$(date +'%Y-%m-%d_%H-%M-%S')"
  bundle="${CRASH_PATH}/rust_crash_${ts}.tgz"
  log "Creating crash bundle at ${bundle}"
  tar -czf "${bundle}" --ignore-failed-read ./latest.log ./logs 2>/dev/null || true
  good "Crash bundle written: ${bundle}"
}

# -------- Supervision loop (ping-only) --------
child_pid=""; term_requested="0"
trap 'term_requested="1"; [[ -n "${child_pid}" ]] && kill -TERM "${child_pid}" 2>/dev/null || true' TERM INT

log "Launching via wrapper (argv mode)…"
while :; do
  /opt/node/bin/node "$WRAPPER" --argv "${ARGV[@]}" &
  child_pid="$!"

  if [[ "${WATCH_ENABLED}" == "1" ]]; then
    ( wait_until_ready; kill -0 "${child_pid}" 2>/dev/null && ping_watch "${child_pid}" ) & stall_pid="$!"
  fi

  rc=0
  wait "${child_pid}" || rc=$?

  [[ -n "${stall_pid:-}" ]] && kill -TERM "${stall_pid}" 2>/dev/null || true
  unset stall_pid

  if [[ "${WATCH_ENABLED}" != "1" || "${rc}" -eq 0 || "${term_requested}" == "1" ]]; then
    [[ "${rc}" -ne 0 ]] && make_crash_bundle
    run_shutdown_cmds
    exit "${rc}"
  fi

  warn "Server crashed/terminated (rc=${rc}). Restarting in 5s…"
  make_crash_bundle
  sleep 5
done
