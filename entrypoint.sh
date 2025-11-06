#!/bin/bash
set -euo pipefail
export HOME=/home/container
cd /home/container

log() { echo -e "[entrypoint] $*"; }

# Preflight niceties
ulimit -n 65535 || true
umask 002

CURL="curl -fSL --retry 5 --retry-delay 2 --connect-timeout 15 --max-time 0"

# Helpers to detect presence
have_oxide()  { [[ -d "/home/container/oxide" ]]; }
have_carbon() { [[ -d "/home/container/carbon" ]]; }

uninstall_oxide() {
  if have_oxide; then
    log "Removing Oxide files…"
    rm -rf /home/container/oxide
    rm -f /home/container/RustDedicated_Data/Managed/{uMod.*,Oxide.*,Carbon.*}.dll || true
  fi
}

uninstall_carbon() {
  if have_carbon; then
    log "Removing Carbon files…"
    rm -rf /home/container/carbon
    rm -f /home/container/RustDedicated_Data/Managed/{Carbon.*,uMod.*,Oxide.*}.dll || true
  fi
}

install_oxide() {
  log "Installing / updating Oxide (uMod)…"
  tmpdir="$(mktemp -d)"
  pushd "$tmpdir" >/dev/null
  $CURL -o oxide.zip "https://umod.org/games/rust/download?build=linux"
  unzip -o oxide.zip -d /home/container
  popd >/dev/null
  rm -rf "$tmpdir"
  log "Oxide install complete."
}

install_carbon() {
  local channel="production" minimal="0"
  case "${FRAMEWORK}" in
    carbon-edge* )    channel="edge" ;;
    carbon-staging* ) channel="staging" ;;
    carbon-aux1* )    channel="aux1" ;;
    carbon-aux2* )    channel="aux2" ;;
    carbon* )         channel="production" ;;
  esac
  [[ "${FRAMEWORK}" == *"-minimal" ]] && minimal="1"

  log "Installing / updating Carbon (channel=${channel}, minimal=${minimal})…"
  tmpdir="$(mktemp -d)"
  pushd "$tmpdir" >/dev/null

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

  [[ -z "${url:-}" ]] && { log "ERROR: Could not map Carbon artifact URL from FRAMEWORK='${FRAMEWORK}'"; exit 10; }
  $CURL "$url" -o carbon.tar.gz
  if [[ -n "${CARBON_SHA256:-}" ]]; then
    echo "${CARBON_SHA256}  carbon.tar.gz" | sha256sum -c -
  fi
  tar -xzf carbon.tar.gz -C /home/container
  popd >/dev/null
  rm -rf "$tmpdir"
  log "Carbon install complete."
}

validate_if_requested() {
  if [[ "${VALIDATE:-0}" == "1" ]]; then
    log "VALIDATE=1 (validation should occur in the egg install step; skipping here)."
  fi
}

# Auto-detect app public IP if blank (optional convenience)
if [[ -z "${APP_PUBLIC_IP:-}" ]]; then
  APP_PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  export APP_PUBLIC_IP
fi

# Mutual exclusivity: install only the selected framework, remove the other
case "${FRAMEWORK:-vanilla}" in
  vanilla )
    log "Framework: vanilla (no mod loader)."
    ;;
  oxide* )
    uninstall_carbon
    if [[ "${FRAMEWORK_UPDATE:-1}" == "1" || ! have_oxide ]]; then
      install_oxide
    else
      log "FRAMEWORK_UPDATE=0 and Oxide present; skipping install."
    fi
    ;;
  carbon* )
    uninstall_oxide
    if [[ "${FRAMEWORK_UPDATE:-1}" == "1" || ! have_carbon ]]; then
      install_carbon
    else
      log "FRAMEWORK_UPDATE=0 and Carbon present; skipping install."
    fi
    ;;
  * )
    log "Unknown FRAMEWORK='${FRAMEWORK}'. Defaulting to vanilla."
    ;;
esac

validate_if_requested

# Trap for graceful shutdowns even before wrapper attaches RCON
trap 'echo "[entrypoint] SIGTERM received"; pkill -TERM -f RustDedicated || true' TERM INT

# Hand off to the wrapper, which will spawn RustDedicated with your startup
if [[ "$#" -gt 0 ]]; then
  log "Launching via wrapper: $*"
  exec node /home/container/wrapper.js "$@"
else
  log "No startup command provided by panel; sleeping…"
  sleep infinity
fi
