#!/usr/bin/env bash
set -euo pipefail

# -------- Config defaults (safe if Pterodactyl doesn't set them) --------
: "${HOME:=/mnt/server}"
: "${TZ:=UTC}"
: "${FRAMEWORK:=vanilla}"
: "${FRAMEWORK_UPDATE:=1}"
: "${VALIDATE:=1}"
: "${STEAMCMDDIR:=/mnt/server/steamcmd}"          # writable path
: "${STARTUP_DONE_TOKEN:=Server startup complete}"

# Pterodactyl variables your egg defines
: "${SERVER_PORT:=28015}"
: "${QUERY_PORT:=28017}"
: "${RCON_PORT:=28016}"
: "${RCON_PASS:=CHANGEME}"
: "${APP_PORT:=28082}"
: "${PREFLIGHT_PORTCHECK:=1}"

# Logging
: "${LATEST_LOG:=latest.log}"                     # wrapper-captured RCON/console output
: "${LOG_FILE:=logs/$(date +'%Y-%m-%d-%H%M').log}" # RustDedicated -logfile
: "${CRASH_ARCHIVE:=1}"
: "${CRASH_PATH:=/home/container/crashdumps}"

# Shutdown / watchdog
: "${SHUTDOWN_RCON_CMDS:=}"                       # e.g. global.say "Wipe in progress",save.all,quit
: "${SHUTDOWN_CMDS:=}"                            # shell commands, comma-separated
: "${RCON_HOST:=127.0.0.1}"
: "${WATCH_ENABLED:=1}"
: "${HEARTBEAT_TIMEOUT_SEC:=120}"
: "${SHUTDOWN_TIMEOUT_SEC:=30}"

# Steam branch (optional)
: "${STEAM_BRANCH:=}"
: "${STEAM_BRANCH_PASS:=}"

# Timezone
if [ -n "${TZ:-}" ] && [ -e "/usr/share/zoneinfo/$TZ" ]; then
  ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime || true
  echo "$TZ" > /etc/timezone || true
fi

# Ensure basic dirs
mkdir -p "$HOME" "$(dirname "$LOG_FILE")" "$(dirname "$LATEST_LOG")" "$CRASH_PATH" "$STEAMCMDDIR"

# -------- Helpers --------
_port_in_use() {
  # $1 = port, $2 = proto (tcp|udp)
  local port="$1" proto="$2"
  if command -v ss >/dev/null 2>&1; then
    if [ "$proto" = "tcp" ]; then
      ss -H -ltn sport = ":$port" | grep -q .
    else
      ss -H -lun sport = ":$port" | grep -q .
    fi
  else
    # fallback with netstat if available
    if command -v netstat >/dev/null 2>&1; then
      if [ "$proto" = "tcp" ]; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$port\$"
      else
        netstat -lun 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$port\$"
      fi
    else
      return 1
    fi
  fi
}

preflight_ports() {
  echo "[entrypoint] Preflight port check…"
  local fail=0
  if _port_in_use "$SERVER_PORT" tcp; then
    echo "  ERROR: SERVER_PORT $SERVER_PORT (tcp) already in use."; fail=1
  fi
  if _port_in_use "$QUERY_PORT" udp; then
    echo "  ERROR: QUERY_PORT $QUERY_PORT (udp) already in use."; fail=1
  fi
  if _port_in_use "$RCON_PORT" tcp; then
    echo "  ERROR: RCON_PORT $RCON_PORT (tcp) already in use."; fail=1
  fi
  if [ "$APP_PORT" != "-1" ] && _port_in_use "$APP_PORT" tcp; then
    echo "  ERROR: APP_PORT $APP_PORT (tcp) already in use."; fail=1
  fi
  if [ "$fail" -eq 1 ]; then
    echo "Aborting due to conflicting ports."
    exit 98
  fi
  echo "  OK"
}

install_or_update_rust() {
  if [ "${FRAMEWORK_UPDATE}" != "1" ]; then
    echo "[entrypoint] Skipping SteamCMD update (FRAMEWORK_UPDATE=$FRAMEWORK_UPDATE)."
    return
  fi

  local appid=258550
  local force_dir="${HOME}"
  echo "[entrypoint] Running SteamCMD install/update to ${force_dir} (validate=${VALIDATE})."

  # Build SteamCMD command
  local branch_arg=""
  if [ -n "${STEAM_BRANCH}" ]; then
    branch_arg="+app_update ${appid} -beta ${STEAM_BRANCH}"
    if [ -n "${STEAM_BRANCH_PASS}" ]; then
      branch_arg="${branch_arg} -betapassword ${STEAM_BRANCH_PASS}"
    fi
  else
    branch_arg="+app_update ${appid}"
  fi
  if [ "${VALIDATE}" = "1" ]; then
    branch_arg="${branch_arg} validate"
  fi

  /home/steam/steamcmd/steamcmd.sh +force_install_dir "${force_dir}" +login anonymous ${branch_arg} +quit
}

# Optional: map framework label to operational mode (actual plugin/framework install handled elsewhere)
normalize_framework() {
  case "${FRAMEWORK}" in
    vanilla|vanilla-staging|vanilla-aux1|vanilla-aux2) echo "vanilla" ;;
    oxide|oxide-staging) echo "oxide" ;;
    carbon|carbon-*) echo "carbon" ;;
    *) echo "vanilla" ;;
  esac
}

# -------- Run steps --------
echo "[entrypoint] Cobalt Rust container starting (TZ=${TZ})"

if [ "${PREFLIGHT_PORTCHECK}" = "1" ]; then
  preflight_ports
else
  echo "[entrypoint] Port preflight disabled."
fi

install_or_update_rust

# Make sure the wrapper log file exists (so Pterodactyl can tail immediately)
touch "${LATEST_LOG}"

# Export envs the wrapper expects (some are already set, re-export to be explicit)
export STARTUP_DONE_TOKEN LATEST_LOG LOG_FILE CRASH_ARCHIVE CRASH_PATH
export RCON_HOST RCON_PORT RCON_PASS SHUTDOWN_RCON_CMDS SHUTDOWN_CMDS
export WATCH_ENABLED HEARTBEAT_TIMEOUT_SEC SHUTDOWN_TIMEOUT_SEC
export APP_PORT QUERY_PORT SERVER_PORT

echo "[entrypoint] Launching wrapper…"
exec node /opt/cobalt/wrapper.js -- "$@"
