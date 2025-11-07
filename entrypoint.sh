#!/bin/bash
set -euo pipefail

# hard-bind everything to /mnt/server (the Wings mount)
export HOME=/mnt/server
cd /mnt/server

log() { echo -e "[entrypoint] $*"; }

# niceties
ulimit -n 65535 || true
umask 002

# config/env
CURL="curl -fSL --retry 5 --retry-delay 2 --connect-timeout 15 --max-time 0"
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
STARTUP="${STARTUP:-}"

# log file path (lives in /mnt/server)
export LATEST_LOG="${LATEST_LOG:-/mnt/server/latest.log}"

# optional public IP
if [[ -z "${APP_PUBLIC_IP:-}" ]]; then
  APP_PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  export APP_PUBLIC_IP
fi

########## helpers ##########
have_oxide()  { [[ -d "/mnt/server/oxide" ]]; }
have_carbon() { [[ -d "/mnt/server/carbon" ]]; }

uninstall_oxide() {
  if have_oxide; then
    log "Removing Oxide…"
    rm -rf /mnt/server/oxide || true
  fi
}

uninstall_carbon() {
  if have_carbon; then
    log "Removing Carbon files…"
    rm -f  /mnt/server/Carbon.targets || true
    rm -rf /mnt/server/doorstop_config || true
    rm -f  /mnt/server/winhttp.dll || true
    rm -rf /mnt/server/carbon || true
  fi
}

install_oxide() {
  log "Installing uMod (Oxide)…"
  tmpdir="$(mktemp -d)"
  pushd "$tmpdir" >/dev/null
  $CURL -o oxide.zip "https://umod.org/games/rust/download?build=linux"
  unzip -o oxide.zip -d /mnt/server
  popd >/dev/null
  rm -rf "$tmpdir"
  log "Oxide install complete."
}

install_carbon() {
  local channel="production" minimal="0" url=""
  case "${FRAMEWORK}" in
    carbon-edge* )    channel="edge" ;;
    carbon-staging* ) channel="staging" ;;
    carbon-aux1* )    channel="aux1" ;;
    carbon-aux2* )    channel="aux2" ;;
    carbon* )         channel="production" ;;
  esac
  [[ "${FRAMEWORK}" == *"-minimal" ]] && minimal="1"

  log "Installing Carbon (channel=${channel}, minimal=${minimal})…"
  tmpdir="$(mktemp -d)"
  pushd "$tmpdir" >/dev/null

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

  $CURL "$url" -o carbon.tar.gz
  tar -xzf carbon.tar.gz -C /mnt/server
  popd >/dev/null
  rm -rf "$tmpdir"
  log "Carbon install complete."
}

steamcmd_path() {
  if [[ -x "/mnt/server/steamcmd/steamcmd.sh" ]]; then echo "/mnt/server/steamcmd/steamcmd.sh"; return; fi
  if [[ -x "/mnt/server/steamcmd.sh" ]]; then echo "/mnt/server/steamcmd.sh"; return; fi
  if [[ -x "/home/steam/steamcmd/steamcmd.sh" ]]; then echo "/home/steam/steamcmd/steamcmd.sh"; return; fi
  if command -v steamcmd >/dev/null 2>&1; then command -v steamcmd; return; fi
  if [[ -x "/usr/games/steamcmd" ]]; then echo "/usr/games/steamcmd"; return; fi
  echo ""
}

validate_now() {
  [[ "$VALIDATE" != "1" ]] && return

  local SCMD; SCMD="$(steamcmd_path)"
  [[ -z "$SCMD" ]] && { log "ERROR: steamcmd not found!"; exit 11; }

  local BRANCH_FLAGS=""
  if [[ -n "$STEAM_BRANCH" ]]; then
    BRANCH_FLAGS="-beta ${STEAM_BRANCH}"
    if [[ -n "$STEAM_BRANCH_PASS" ]]; then
      BRANCH_FLAGS="${BRANCH_FLAGS} -betapassword ${STEAM_BRANCH_PASS}"
    fi
  fi

  log "Validating via steamcmd…"
  "$SCMD" +force_install_dir /mnt/server \
         +login "${STEAM_USER}" "${STEAM_PASS}" "${STEAM_AUTH}" \
         +app_update "${SRCDS_APPID}" ${BRANCH_FLAGS} ${EXTRA_FLAGS} validate \
         +quit
  log "Validation complete."
}

########## MAIN ##########
case "${FRAMEWORK}" in
  vanilla)
    uninstall_oxide
    uninstall_carbon
    ;;
  oxide|uMod)
    uninstall_carbon
    validate_now
    install_oxide
    ;;
  carbon*)
    uninstall_oxide
    validate_now
    install_carbon
    ;;
  *)
    log "Unknown framework '${FRAMEWORK}', defaulting to vanilla."
    uninstall_oxide
    uninstall_carbon
    ;;
esac

# ensure at least one validation has happened if requested
validate_now

[[ -z "${STARTUP}" ]] && { log "ERROR: No STARTUP command provided."; exit 12; }

log "Launching server with wrapper: ${STARTUP}"
# pass LATEST_LOG so wrapper writes inside /mnt/server
exec env LATEST_LOG="${LATEST_LOG}" /opt/node/bin/node /opt/cobalt/wrapper.js "${STARTUP}"
