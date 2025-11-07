#!/bin/bash
set -euo pipefail

# =======================================================================
# Rust Dedicated Server entrypoint for Pterodactyl (argv-safe)
# - Uses env-provided argv (JSON/Base64/file) if available (zero splitting)
# - Otherwise parses panel Start Command/STARTUP and repairs split values
# - Installs/validates Vanilla / Oxide / Carbon
# - Launches via wrapper.js, which tails -logfile and mirrors output
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
# Build argv to pass to wrapper
# Priority:
#   1) RUST_ARGS_FILE (NUL/newline-separated)
#   2) RUST_ARGS_B64 (base64 of JSON array)
#   3) RUST_ARGS_JSON (JSON array)
#   4) "$@" (Start Command tokens) or STARTUP expansion -> with repair pass
# -----------------------------------------------------------------------

ARGV=()

# 1) File
if [[ -n "${RUST_ARGS_FILE:-}" && -f "${RUST_ARGS_FILE}" ]]; then
  # Read NUL-separated; if newline-separated, convert to NUL first
  mapfile -d '' -t ARGV < <(tr '\n' '\0' < "${RUST_ARGS_FILE}") || true
fi

# 2) Base64(JSON)
if [[ "${#ARGV[@]}" -eq 0 && -n "${RUST_ARGS_B64:-}" ]]; then
  json="$(printf '%s' "${RUST_ARGS_B64}" | base64 -d 2>/dev/null || true)"
  if [[ -n "${json}" ]]; then
    while IFS= read -r -d '' item; do ARGV+=("$item"); done < <(
      node -e 'try{const a=JSON.parse(require("fs").readFileSync(0,"utf8")); if(!Array.isArray(a))process.exit(1); for(const s of a){process.stdout.write(String(s)); process.stdout.write("\0");}}catch(e){process.exit(2)}' <<<"${json}" || true
    )
  fi
fi

# 3) JSON
if [[ "${#ARGV[@]}" -eq 0 && -n "${RUST_ARGS_JSON:-}" ]]; then
  while IFS= read -r -d '' item; do ARGV+=("$item"); done < <(
    node -e 'try{const a=JSON.parse(require("fs").readFileSync(0,"utf8")); if(!Array.isArray(a))process.exit(1); for(const s of a){process.stdout.write(String(s)); process.stdout.write("\0");}}catch(e){process.exit(2)}' <<<"${RUST_ARGS_JSON}" || true
  )
fi

# 4) Fallback: tokens from Start Command or STARTUP string
if [[ "${#ARGV[@]}" -eq 0 ]]; then
  if [[ "$#" -gt 0 ]]; then
    ARGV=( "$@" )
  else
    if [[ -z "${STARTUP:-}" ]]; then
      err "No startup provided: neither argv env nor Start Command args nor STARTUP env found."
      exit 12
    fi
    # Expand panel variables {{VAR}} -> ${VAR}
    EXPANDED="$(
      eval "echo \"$(printf '%s' "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')\""
    )"
    # Let the shell split into tokens (might split multi-word… we'll repair next)
    eval "set -- ${EXPANDED}"
    ARGV=( "$@" )
  fi

  # ---- REPAIR PASS: rejoin values for flags that commonly include spaces ----
  REJOIN_FLAGS=(
    "-server.hostname"
    "-server.description"
    "-server.tags"
    "-server.url"
    "-rcon.password"
    "-logfile"
  )
  is_flag() { [[ "$1" == -* ]]; }

  repaired=()
  i=0
  while [[ $i -lt ${#ARGV[@]} ]]; do
    tok="${ARGV[$i]}"
    if is_flag "$tok"; then
      repaired+=("$tok")
      ((i++))
      if [[ $i -lt ${#ARGV[@]} ]]; then
        val="${ARGV[$i]}"; ((i++))
        # Slurp additional words until the next token looks like a flag
        # NOTE: fixed regex check; no command substitution (avoids set -e exits)
        while [[ $i -lt ${#ARGV[@]} && ! "${ARGV[$i]}" =~ ^-[-A-Za-z0-9_.]+$ ]]; do
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
fi

# Strip accidental /entrypoint.sh leading token
if [[ "${#ARGV[@]}" -gt 0 && "${ARGV[0]}" == "/entrypoint.sh" ]]; then
  ARGV=( "${ARGV[@]:1}" )
fi

# Ensure the Rust binary exists
if [[ ! -f "./RustDedicated" ]]; then
  err "RustDedicated not found in $(pwd). Did app_update install to /home/container?"
  err "Set VALIDATE=1 and try again."
  exit 13
fi
[[ -x "./RustDedicated" ]] || chmod +x ./RustDedicated || true

log "Launching via wrapper (argv-file mode)…"

# Locate wrapper
WRAPPER="/wrapper.js"
[[ -f "$WRAPPER" ]] || WRAPPER="/opt/cobalt/wrapper.js"
if [[ ! -f "$WRAPPER" ]]; then
  err "wrapper.js not found at /wrapper.js or /opt/cobalt/wrapper.js"
  exit 14
fi
chmod +x "$WRAPPER" || true

# Write ARGV to a NUL-separated file (no splitting)
ARGS_FILE="$(mktemp -p /home/container args.XXXXXXXX.nul)"
# shellcheck disable=SC2059
printf '%s\0' "${ARGV[@]}" > "${ARGS_FILE}"

# Find NodeJS
NODE_BIN="${NODE_BIN:-}"
if [[ -z "${NODE_BIN}" ]]; then
  if command -v node >/dev/null 2>&1; then
    NODE_BIN="$(command -v node)"
  elif [[ -x /opt/node/bin/node ]]; then
    NODE_BIN="/opt/node/bin/node"
  else
    err "NodeJS not found. Set NODE_BIN to your node path, or ensure 'node' is on PATH."
    err "Tried: \$(command -v node), /opt/node/bin/node"
    exit 15
  fi
fi

log "Using node: ${NODE_BIN}"
log "Wrapper: ${WRAPPER}"
log "Args file: ${ARGS_FILE} ($(wc -c < "${ARGS_FILE}") bytes)"

# Optional debug: show first few argv tokens for sanity
{
  printf "[entrypoint] argv[0..7]:"
  tr '\0' '\n' < "${ARGS_FILE}" | head -n 8 | sed 's/^/ /'
} || true

# Exec wrapper (no shell re-parsing)
exec "${NODE_BIN}" "${WRAPPER}" --argv-file "${ARGS_FILE}"
