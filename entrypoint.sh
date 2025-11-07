#!/bin/bash
set -euo pipefail

# =======================================================================
# Rust Dedicated Server entrypoint for Pterodactyl (console-first, argv-safe)
# - Works from /home/container
# - Preserves multi-word values by repairing split tokens and passing
#   a NUL-separated argv file to wrapper.js (no re-splitting)
# - Supports Vanilla / Oxide / Carbon
# - Validates via SteamCMD (optional)
# - Launches via wrapper.js which mirrors logfile to panel
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

FRAMEWORK="${FRAMEWORK:-vanilla}"      # vanilla | oxide | carbon* (edge/staging/auxX, *-minimal)
VALIDATE="${VALIDATE:-1}"
EXTRA_FLAGS="${EXTRA_FLAGS:-}"
STEAM_BRANCH="${STEAM_BRANCH:-}"
STEAM_BRANCH_PASS="${STEAM_BRANCH_PASS:-}"

# wrapper log destination (wrapper writes raw logs here)
export LATEST_LOG="${LATEST_LOG:-/home/container/latest.log}"

# optional convenience IP (panel can override)
if [[ -z "${APP_PUBLIC_IP:-}" ]]; then
  APP_PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  export APP_PUBLIC_IP
fi

# -----------------------------------------------------------------------
# Update / validate
# -----------------------------------------------------------------------
do_validate() {
  [[ "${VALIDATE}" != "1" ]] && return 0
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

  if [[ -z "${url}" ]]; then
    err "Could not determine Carbon artifact for FRAMEWORK='${FRAMEWORK}'"
    exit 10
  fi

  local tmp; tmp="$(mktemp -d)"
  pushd "$tmp" >/dev/null
  curl -fSL --retry 5 -o carbon.tar.gz "${url}"
  tar -xzf carbon.tar.gz -C /home/container
  popd >/dev/null
  rm -rf "$tmp"
  log "Carbon install complete."
}

# run chosen framework steps
case "${FRAMEWORK}" in
  oxide|uMod) do_validate; install_oxide ;;
  carbon*  ) do_validate; install_carbon ;;
  *        ) do_validate ;;  # vanilla
esac

# -----------------------------------------------------------------------
# Build argv to pass to wrapper (start-command or STARTUP)
# -----------------------------------------------------------------------

# If args were passed after /entrypoint.sh, use them as-is.
if [[ "$#" -gt 0 ]]; then
  ARGV=( "$@" )
else
  # STARTUP env expansion: convert {{VAR}} → ${VAR}, expand, then parse into argv
  if [[ -z "${STARTUP:-}" ]]; then
    err "No startup provided: neither Start Command args nor STARTUP env found."
    exit 12
  fi
  # Expand panel variables while preserving quotes
  EXPANDED="$(
    eval "echo \"$(printf '%s' "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')\""
  )"
  # Parse EXPANDED into $1..$N (argv) using the shell's own parser
  eval "set -- ${EXPANDED}"
  ARGV=( "$@" )
fi

# If someone accidentally included /entrypoint.sh, strip it.
if [[ "${#ARGV[@]}" -gt 0 && "${ARGV[0]}" == "/entrypoint.sh" ]]; then
  ARGV=( "${ARGV[@]:1}" )
fi

# ---- REPAIR PASS: rejoin values that were split by the panel/shell ----
# Treat both '-' and '+' prefixed tokens as flags.
is_flag() { [[ "$1" == -* || "$1" == +* ]]; }

repaired=()
i=0
while [[ $i -lt ${#ARGV[@]} ]]; do
  tok="${ARGV[$i]}"
  if is_flag "$tok"; then
    repaired+=("$tok")
    ((i++))
    if [[ $i -lt ${#ARGV[@]} ]]; then
      val="${ARGV[$i]}"; ((i++))
      # Keep joining until next token *looks like* a flag (-or+ prefix)
      while [[ $i -lt ${#ARGV[@]} && ! "${ARGV[$i]}" =~ ^[-+][A-Za-z0-9_.-]+$ ]]; do
        val+=" ${ARGV[$i]}"
        ((i++))
      done
      repaired+=("$val")
    fi
  else
    repaired+=("$tok")
    ((i++))
  fi
done
ARGV=( "${repaired[@]}" )

# Ensure the Rust binary exists & is executable (ARGV[0] should be ./RustDedicated)
if [[ ! -f "./RustDedicated" ]]; then
  err "RustDedicated not found in $(pwd). Did app_update install to /home/container?"
  err "Set VALIDATE=1 (or enable AUTO_UPDATE in your egg) and try again."
  exit 13
fi
[[ -x "./RustDedicated" ]] || chmod +x ./RustDedicated || true

log "Launching via wrapper (argv-file mode)…"

# pick wrapper path (either location is fine)
WRAPPER="/wrapper.js"
[[ -f "$WRAPPER" ]] || WRAPPER="/opt/cobalt/wrapper.js"
if [[ ! -f "$WRAPPER" ]]; then
  err "wrapper.js not found at /wrapper.js or /opt/cobalt/wrapper.js"
  exit 14
fi

# -----------------------------------------------------------------------
# Write argv to a NUL-separated file and pass it to the wrapper.
# This prevents any further splitting of multi-word values.
# -----------------------------------------------------------------------
ARGS_FILE="$(mktemp -p /home/container args.XXXXXXXX.nul)"
# shellcheck disable=SC2059
printf '%s\0' "${ARGV[@]}" > "${ARGS_FILE}"

# Find Node (prefer /opt path, else PATH)
NODE_BIN="/opt/node/bin/node"
if [[ ! -x "${NODE_BIN}" ]]; then
  if command -v node >/dev/null 2>&1; then
    NODE_BIN="$(command -v node)"
  else
    err "NodeJS not found. Tried /opt/node/bin/node and PATH."
    exit 15
  fi
fi

# Optional breadcrumbs (handy if something still fails very early)
log "Using node: ${NODE_BIN}"
log "Wrapper: ${WRAPPER}"
log "Args file: ${ARGS_FILE} ($(wc -c < "${ARGS_FILE}") bytes)"
{ printf "[entrypoint] argv[0..7] preview:"; tr '\0' '\n' < "${ARGS_FILE}" | head -n 8 | sed 's/^/ /'; } || true

# Exec wrapper (no shell re-parsing)
exec "${NODE_BIN}" "${WRAPPER}" --argv-file "${ARGS_FILE}"
