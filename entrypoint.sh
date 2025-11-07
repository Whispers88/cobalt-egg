#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------
# Pterodactyl entrypoint (setup only, then pass args through)
# ------------------------------------------------------------

# Use the mounted server volume most nodes provide
export HOME=/home/container
cd /home/container

log() { echo -e "[entrypoint] $*"; }

# Niceties
ulimit -n 65535 || true
umask 002

# SteamCMD dirs under /home/container
mkdir -p \
  /home/container/Steam/package \
  /home/container/steamcmd \
  /home/container/steamapps \
  /home/container/.steam/sdk32 \
  /home/container/.steam/sdk64 || true

# Ensure writable (won’t hurt if already owned)
chown -R "$(id -u)":"$(id -g)" /home/container || true

# Help SteamCMD keep its cache here
export STEAMCMDDIR=/home/container/steamcmd

# ---- Optional: validation / framework handling ----
CURL="curl -fSL --retry 5 --retry-delay 2 --connect-timeout 15 --max-time 0"
SRCDS_APPID="${SRCDS_APPID:-258550}"
STEAM_USER="${STEAM_USER:-anonymous}"
STEAM_PASS="${STEAM_PASS:-}"
STEAM_AUTH="${STEAM_AUTH:-}"
FRAMEWORK="${FRAMEWORK:-vanilla}"
VALIDATE="${VALIDATE:-0}"          # default off so Panel fully controls behavior
EXTRA_FLAGS="${EXTRA_FLAGS:-}"
STEAM_BRANCH="${STEAM_BRANCH:-}"
STEAM_BRANCH_PASS="${STEAM_BRANCH_PASS:-}"

have_oxide()  { [[ -d "/home/container/oxide" ]]; }
have_carbon() { [[ -d "/home/container/carbon" ]]; }

uninstall_oxide()  { have_oxide  && rm -rf /home/container/oxide || true; }
uninstall_carbon() {
  have_carbon && {
    rm -f  /home/container/Carbon.targets /home/container/winhttp.dll || true
    rm -rf /home/container/doorstop_config /home/container/carbon   || true
  }
}

install_oxide() {
  local tmp; tmp="$(mktemp -d)"
  pushd "$tmp" >/dev/null
  $CURL -o oxide.zip "https://umod.org/games/rust/download?build=linux"
  unzip -o oxide.zip -d /home/container
  popd >/dev/null
  rm -rf "$tmp"
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
  [[ -z "$url" ]] || { curl -fSL "$url" -o carbon.tar.gz && tar -xzf carbon.tar.gz -C /home/container && rm -f carbon.tar.gz; }
}

steamcmd_path() {
  if [[ -x "/home/container/steamcmd/steamcmd.sh" ]]; then echo "/home/container/steamcmd/steamcmd.sh"; return; fi
  if [[ -x "/home/container/steamcmd.sh" ]]; then echo "/home/container/steamcmd.sh"; return; fi
  if [[ -x "/home/steam/steamcmd/steamcmd.sh" ]]; then echo "/home/steam/steamcmd/steamcmd.sh"; return; fi
  if command -v steamcmd >/dev/null 2>&1; then command -v steamcmd; return; fi
  if [[ -x "/usr/games/steamcmd" ]]; then echo "/usr/games/steamcmd"; return; fi
  echo ""
}

validate_now() {
  [[ "${VALIDATE}" != "1" ]] && return
  local SCMD; SCMD="$(steamcmd_path)"
  [[ -z "$SCMD" ]] && { log "ERROR: steamcmd not found"; exit 11; }
  local BRANCH_FLAGS=""
  if [[ -n "$STEAM_BRANCH" ]]; then
    BRANCH_FLAGS="-beta ${STEAM_BRANCH}"
    [[ -n "$STEAM_BRANCH_PASS" ]] && BRANCH_FLAGS+=" -betapassword ${STEAM_BRANCH_PASS}"
  fi
  log "Validating via SteamCMD…"
  "$SCMD" +force_install_dir /home/container \
         +login "${STEAM_USER}" "${STEAM_PASS}" "${STEAM_AUTH}" \
         +app_update "${SRCDS_APPID}" ${BRANCH_FLAGS} ${EXTRA_FLAGS} validate \
         +quit
}

# Optional framework maintenance; you can fully control by Panel variables too
case "${FRAMEWORK}" in
  vanilla) uninstall_oxide; uninstall_carbon ;;
  oxide|uMod) uninstall_carbon; validate_now; install_oxide ;;
  carbon*) uninstall_oxide; validate_now; install_carbon ;;
  *) uninstall_oxide; uninstall_carbon ;;
esac

# One more validation if requested
validate_now

# ---- Don’t print the full command; just run the wrapper with all args ----
export LATEST_LOG="${LATEST_LOG:-/home/container/latest.log}"
echo "[entrypoint] Starting server…"  # safe, no args leaked

# Forward **all** Start Command arguments to the wrapper; the wrapper runs them under bash
exec env LATEST_LOG="${LATEST_LOG}" /opt/node/bin/node /opt/cobalt/wrapper.js "$@"
