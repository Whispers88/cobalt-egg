#!/usr/bin/env bash
set -euo pipefail

# -------- Defaults --------
: "${HOME:=/mnt/server}"
: "${TZ:=UTC}"
: "${FRAMEWORK:=vanilla}"
: "${FRAMEWORK_UPDATE:=1}"
: "${VALIDATE:=1}"
: "${STEAMCMDDIR:=/mnt/server/steamcmd}"
: "${STARTUP_DONE_TOKEN:=Server startup complete}"

: "${SERVER_PORT:=28015}"
: "${QUERY_PORT:=28017}"
: "${RCON_PORT:=28016}"
: "${RCON_PASS:=CHANGEME}"
: "${APP_PORT:=28082}"
: "${PREFLIGHT_PORTCHECK:=1}"

: "${LATEST_LOG:=latest.log}"
: "${LOG_FILE:=logs/$(date +'%Y-%m-%d-%H%M').log}"
: "${CRASH_ARCHIVE:=1}"
: "${CRASH_PATH:=/home/container/crashdumps}"

: "${SHUTDOWN_RCON_CMDS:=}"
: "${SHUTDOWN_CMDS:=}"
: "${RCON_HOST:=127.0.0.1}"
: "${WATCH_ENABLED:=1}"
: "${HEARTBEAT_TIMEOUT_SEC:=120}"
: "${SHUTDOWN_TIMEOUT_SEC:=30}"

: "${STEAM_BRANCH:=}"
: "${STEAM_BRANCH_PASS:=}"

# -------- Helpers --------
is_dir_writable() { test -d "$1" && test -w "$1"; }
ensure_writable_dir() {
  # $1 desired dir, $2 fallback dir
  local want="$1" fallback="$2"
  if mkdir -p "$want" 2>/dev/null; then
    echo "$want"
  else
    mkdir -p "$fallback"
    echo "$fallback"
  fi
}

# -------- Timezone (don’t touch /etc if ro) --------
if [ -e "/usr/share/zoneinfo/$TZ" ] && [ -w /etc ] && [ -w /etc/localtime ] 2>/dev/null; then
  ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime || true
  { echo "$TZ" > /etc/timezone; } || true
else
  echo "[entrypoint] Not writing /etc/timezone (read-only). Using TZ=${TZ} via environment only."
fi
export TZ

# -------- Writable locations (with fallbacks to /tmp) --------
# HOME (intended game dir)
if ! is_dir_writable "$HOME"; then
  echo "[entrypoint] HOME=$HOME is not writable; switching HOME to /tmp/cobalt/home"
  HOME="/tmp/cobalt/home"; export HOME
fi
mkdir -p "$HOME" || true

# Crash path
CRASH_PATH="$(ensure_writable_dir "$CRASH_PATH" "/tmp/cobalt/crashdumps")"; export CRASH_PATH

# Logs: pick a base dir and rewrite LOG_FILE/LATEST_LOG to writable paths if needed
logs_base="$HOME/logs"
if ! mkdir -p "$logs_base" 2>/dev/null; then
  logs_base="/tmp/cobalt/logs"
  mkdir -p "$logs_base"
  echo "[entrypoint] Log dir not writable; falling back to $logs_base"
fi

# If LOG_FILE is relative, move it under logs_base
case "$LOG_FILE" in
  /*) true ;; # absolute
  *) LOG_FILE="${logs_base}/$(basename "$LOG_FILE")" ;;
esac
# If LATEST_LOG is relative, move it under logs_base
case "$LATEST_LOG" in
  /*) true ;;
  *) LATEST_LOG="${logs_base}/$(basename "$LATEST_LOG")" ;;
esac
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$LATEST_LOG")"
touch "$LATEST_LOG" || { echo "[entrypoint] WARN: cannot create $LATEST_LOG"; }

export LOG_FILE LATEST_LOG

# SteamCMD dir: ensure writable or use /tmp
if ! mkdir -p "$STEAMCMDDIR" 2>/dev/null; then
  STEAMCMDDIR="/tmp/steamcmd"
  mkdir -p "$STEAMCMDDIR"
  echo "[entrypoint] STEAMCMDDIR not writable; using $STEAMCMDDIR"
fi
export STEAMCMDDIR

# -------- Port preflight (best-effort) --------
_port_in_use() {
  local port="$1" proto="$2"
  if command -v ss >/dev/null 2>&1; then
    if [ "$proto" = "tcp" ]; then ss -H -ltn sport = ":$port" | grep -q .; else ss -H -lun sport = ":$port" | grep -q .; fi
  else
    return 1
  fi
}
preflight_ports() {
  echo "[entrypoint] Preflight port check…"
  local fail=0
  _port_in_use "$SERVER_PORT" tcp && { echo "  ERROR: SERVER_PORT $SERVER_PORT (tcp) in use."; fail=1; }
  _port_in_use "$QUERY_PORT" udp && { echo "  ERROR: QUERY_PORT $QUERY_PORT (udp) in use."; fail=1; }
  _port_in_use "$RCON_PORT"  tcp && { echo "  ERROR: RCON_PORT $RCON_PORT (tcp) in use."; fail=1; }
  [ "$APP_PORT" != "-1" ] && _port_in_use "$APP_PORT" tcp && { echo "  ERROR: APP_PORT $APP_PORT (tcp) in use."; fail=1; }
  [ "$fail" -eq 1 ] && { echo "Aborting due to conflicting ports."; exit 98; }
  echo "  OK"
}

# -------- Steam install/update (best-effort; skip if steamcmd missing) --------
install_or_update_rust() {
  [ "${FRAMEWORK_UPDATE}" != "1" ] && { echo "[entrypoint] Skipping SteamCMD update."; return; }
  if [ ! -x "/home/steam/steamcmd/steamcmd.sh" ] && [ ! -x "/home/steam/steamcmd/steamcmd" ]; then
    echo "[entrypoint] steamcmd not found; skipping update."
    return
  fi
  local appid=258550 force_dir="${HOME}"
  local branch_arg=""
  if [ -n "${STEAM_BRANCH}" ]; then
    branch_arg="+app_update ${appid} -beta ${STEAM_BRANCH}"
    [ -n "${STEAM_BRANCH_PASS}" ] && branch_arg="${branch_arg} -betapassword ${STEAM_BRANCH_PASS}"
  else
    branch_arg="+app_update ${appid}"
  fi
  [ "${VALIDATE}" = "1" ] && branch_arg="${branch_arg} validate"
  echo "[entrypoint] SteamCMD updating Rust to ${force_dir} (validate=${VALIDATE})"
  /home/steam/steamcmd/steamcmd.sh +force_install_dir "${force_dir}" +login anonymous ${branch_arg} +quit || \
  /home/steam/steamcmd/steamcmd +force_install_dir "${force_dir}" +login anonymous ${branch_arg} +quit || \
  echo "[entrypoint] WARN: SteamCMD update failed (continuing)."
}

# -------- Run --------
echo "[entrypoint] Cobalt Rust container starting (TZ=${TZ})"
[ "${PREFLIGHT_PORTCHECK}" = "1" ] && preflight_ports || echo "[entrypoint] Port preflight disabled."
install_or_update_rust

# Export for wrapper
export STARTUP_DONE_TOKEN CRASH_ARCHIVE RCON_HOST RCON_PORT RCON_PASS \
       SHUTDOWN_RCON_CMDS SHUTDOWN_CMDS WATCH_ENABLED HEARTBEAT_TIMEOUT_SEC SHUTDOWN_TIMEOUT_SEC \
       APP_PORT QUERY_PORT SERVER_PORT

echo "[entrypoint] Launching wrapper…"
exec node /opt/cobalt/wrapper.js -- "$@"
