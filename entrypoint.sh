#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------
# Rust Dedicated Server entrypoint (no-symlink, /mnt/server)
# ------------------------------------------------------------

# Run everything from the Wings-mounted server volume
export HOME=/mnt/server
cd /mnt/server

log() { echo -e "[entrypoint] $*"; }

# Niceties
ulimit -n 65535 || true
umask 002

# ------------------------------------------------------------
# SteamCMD preflight for no-symlink mode
# Steam uses $HOME/Steam/...; we ensure dirs exist under /mnt/server
# ------------------------------------------------------------
mkdir -p \
  /mnt/server/Steam/package \
  /mnt/server/steamcmd \
  /mnt/server/steamapps \
  /mnt/server/.steam/sdk32 \
  /mnt/server/.steam/sdk64

# Ensure the unprivileged user can write to the mounted volume
chown -R "$(id -u)":"$(id -g)" /mnt/server || true

# Hint SteamCMD to keep cache/tools here
export STEAMCMDDIR=/mnt/server/steamcmd

# ------------------------------------------------------------
# Config / Environment
# ------------------------------------------------------------
CURL="curl -fSL --retry 5 --retry-delay 2 --connect-timeout 15 --max-time 0"

SRCDS_APPID="${SRCDS_APPID:-258550}"

STEAM_USER="${STEAM_USER:-anonymous}"
STEAM_PASS="${STEAM_PASS:-}"
STEAM_AUTH="${STEAM_AUTH:-}"

FRAMEWORK="${FRAMEWORK:-vanilla}"          # vanilla | oxide | carbon* (carbon, carbon-edge, carbon-staging, etc.)
FRAMEWORK_UPDATE="${FRAMEWORK_UPDATE:-1}"   # reserved, not used, kept for compatibility
VALIDATE="${VALIDATE:-1}"                   # 1 to validate (recommended)
EXTRA_FLAGS="${EXTRA_FLAGS:-}"              # extra args for +app_update (e.g., -validate)
STEAM_BRANCH="${STEAM_BRANCH:-}"            # branch name (optional)
STEAM_BRANCH_PASS="${STEAM_BRANCH_PASS:-}"  # branch password (optional)

STARTUP="${STARTUP:-}"                      # Pterodactyl STARTUP string

# Log file (lives in the mounted volume)
export LATEST_LOG="${LATEST_LOG:-/mnt/server/latest.log}"

# Optional public IP detection
if [[ -z "${APP_PUBLIC_IP:-}" ]]; then
  APP_PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  export APP_PUBLIC_IP
fi

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
have_oxide()  { [[ -d "/mnt/server/oxide" ]]; }
have_carbon() { [[ -d "/mnt/server/carbon" ]]; }

uninstall_oxide() {
  if have_oxide; then
    log "Removing Oxide/uMod files…"
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
  local tmpdir
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
  local tmpdir
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
      staging)    url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/downloa
