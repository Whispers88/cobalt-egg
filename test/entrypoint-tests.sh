#!/bin/bash
# Entrypoint scenario tests — runs entrypoint.sh against a temp COBALT_HOME with
# a stub wrapper (prints the argv it received) and no real steamcmd.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EP="$ROOT/entrypoint.sh"
STUB="$ROOT/test/stub-wrapper.js"

PASS=0; FAIL=0
ok()   { echo "  ok: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# mirrors the real egg startup: seed + map url come from env (WORLD_SEED / MAP_URL)
STARTUP_BASE='./RustDedicated -batchmode +server.identity \"rust\" +server.hostname \"My Cool Host\" $( [ -z ${MAP_URL} ] && printf %s "+server.worldsize \"3000\" +server.seed \"${WORLD_SEED}\"" || printf %s "+server.levelurl ${MAP_URL}" ) +rcon.web true'

new_home() {
  H="$(mktemp -d)"
  mkdir -p "$H/.cobalt" "$H/steamapps"
  printf '#!/bin/sh\n' > "$H/RustDedicated"
  chmod +x "$H/RustDedicated"
}
write_acf() { # buildid
  printf '"AppState"\n{\n\t"appid"\t\t"258550"\n\t"buildid"\t\t"%s"\n\t"InstalledDepots"\n\t{\n\t\t"258551"\n\t\t{\n\t\t\t"manifest"\t\t"7777777777"\n\t\t}\n\t}\n}\n' "$1" > "$H/steamapps/appmanifest_258550.acf"
}
run_ep() { # extra KEY=VAL pairs as args
  OUT="$(env COBALT_HOME="$H" COBALT_WRAPPER="$STUB" \
      AUTO_UPDATE=0 FRAMEWORK_UPDATE=0 VALIDATE=0 \
      PREFLIGHT_PORTCHECK=0 OOM_WATCH=0 DISK_MIN_FREE_MB=0 \
      SERVER_IDENTITY=rust MAP_URL="" WORLD_SEED=1234 STARTUP="$STARTUP_BASE" \
      "$@" bash "$EP" 2>&1)"
  RC=$?
}

echo "Scenario A: map wipe"
new_home
mkdir -p "$H/server/rust"
touch "$H/server/rust/proc.map" "$H/server/rust/proc.sav" "$H/server/rust/proc.sav.1" "$H/server/rust/player.blueprints.5.db"
printf 'map' > "$H/.cobalt/pending_wipe"
run_ep
check "exit 0"                        '[[ $RC -eq 0 ]]'
check "*.map deleted"                 '[[ ! -e "$H/server/rust/proc.map" ]]'
check "*.sav deleted"                 '[[ ! -e "$H/server/rust/proc.sav" ]]'
check "*.sav.N backups deleted"       '[[ ! -e "$H/server/rust/proc.sav.1" ]]'
check "blueprints KEPT on map wipe"   '[[ -e "$H/server/rust/player.blueprints.5.db" ]]'
check "flag consumed"                 '[[ ! -e "$H/.cobalt/pending_wipe" ]]'

echo "Scenario B: full wipe"
new_home
mkdir -p "$H/server/rust"
touch "$H/server/rust/proc.map" "$H/server/rust/player.blueprints.5.db" "$H/server/rust/player.deaths.5.db" "$H/server/rust/player.tokens.db"
printf 'full' > "$H/.cobalt/pending_wipe"
run_ep
check "blueprints deleted"            '[[ ! -e "$H/server/rust/player.blueprints.5.db" ]]'
check "deaths deleted"                '[[ ! -e "$H/server/rust/player.deaths.5.db" ]]'
check "map deleted"                   '[[ ! -e "$H/server/rust/proc.map" ]]'

echo "Scenario C: seed rotation (random)"
new_home
mkdir -p "$H/server/rust"
printf 'map' > "$H/.cobalt/pending_wipe"
run_ep WIPE_NEW_SEED=random
SEED="$(cat "$H/.cobalt/seed" 2>/dev/null || echo MISSING)"
check "seed file written"             '[[ "$SEED" != "MISSING" && -n "$SEED" ]]'
check "seed overridden in argv"       'echo "$OUT" | grep -q "\"+server.seed\",\"$SEED\""'
check "old seed 1234 gone from argv"  '! echo "$OUT" | grep -q "\"+server.seed\",\"1234\""'

echo "Scenario D: seed rotation (csv list)"
new_home
mkdir -p "$H/server/rust"
printf 'map' > "$H/.cobalt/pending_wipe"
run_ep WIPE_NEW_SEED="111,222,333"
S1="$(cat "$H/.cobalt/seed")"
printf 'map' > "$H/.cobalt/pending_wipe"
run_ep WIPE_NEW_SEED="111,222,333"
S2="$(cat "$H/.cobalt/seed")"
check "csv rotation starts at first"  '[[ "$S1" == "111" && "$S2" == "222" ]]'
check "seed substituted into argv"    'echo "$OUT" | grep -q "\"+server.seed\",\"222\""'

echo "Scenario E: pin match skips steamcmd"
new_home
write_acf 4242
printf '4242' > "$H/.cobalt/pin"
run_ep AUTO_UPDATE=1
check "exit 0 (no steamcmd needed)"   '[[ $RC -eq 0 ]]'
check "pinned message"                'echo "$OUT" | grep -q "PINNED to build 4242"'

echo "Scenario F: pin mismatch boots as-installed"
new_home
write_acf 5555
printf '4242' > "$H/.cobalt/pin"
run_ep AUTO_UPDATE=1
check "exit 0"                        '[[ $RC -eq 0 ]]'
check "as-installed warning"          'echo "$OUT" | grep -q "AS-INSTALLED"'

echo "Scenario G: PIN_BUILD env seeds pin file"
new_home
write_acf 6161
run_ep AUTO_UPDATE=1 PIN_BUILD=6161
check "pin file seeded"               '[[ "$(cat "$H/.cobalt/pin" 2>/dev/null)" == "6161" ]]'
check "pinned message"                'echo "$OUT" | grep -q "PINNED to build 6161"'

echo "Scenario H: rollback apply"
new_home
write_acf 11111
# live install: an old file that must be replaced, a stale file that must vanish
mkdir -p "$H/RustDedicated_Data" "$H/oxide"
printf 'old' > "$H/RustDedicated_Data/old.dll"
printf 'stale' > "$H/RustDedicated_Data/stale-from-newer-build.dll"
printf 'keep' > "$H/oxide/keep.txt"
# staged depot content
DEPOT="$H/steamcmd/steamapps/content/app_258550/depot_258551"
mkdir -p "$DEPOT/RustDedicated_Data" "$DEPOT/Bundles"
printf 'rolled' > "$DEPOT/RustDedicated_Data/old.dll"
printf 'bundle' > "$DEPOT/Bundles/shared.bundle"
printf '#!/bin/sh\n' > "$DEPOT/RustDedicated"
# archived framework artifact
mkdir -p "$H/.cobalt/frameworks"
TMPART="$(mktemp -d)"
printf 'carbon-bytes' > "$TMPART/carbon-marker.txt"
tar -czf "$H/.cobalt/frameworks/carbon-v1.0.0.tar.gz" -C "$TMPART" carbon-marker.txt
rm -rf "$TMPART"
cat > "$H/.cobalt/pending_rollback" <<EOF
{"buildid":10000,"depots":[{"id":"258551","manifest":"1111111111"}],"framework":"carbon","frameworkVersion":"v1.0.0","frameworkArtifact":"$H/.cobalt/frameworks/carbon-v1.0.0.tar.gz","recorded_at":"2026-07-01T00:00:00.000Z"}
EOF
run_ep
check "exit 0"                        '[[ $RC -eq 0 ]]'
check "depot file applied"            '[[ "$(cat "$H/RustDedicated_Data/old.dll")" == "rolled" ]]'
check "stale newer-build file purged" '[[ ! -e "$H/RustDedicated_Data/stale-from-newer-build.dll" ]]'
check "new top-level dir applied"     '[[ -e "$H/Bundles/shared.bundle" ]]'
check "preserved dir untouched"       '[[ "$(cat "$H/oxide/keep.txt")" == "keep" ]]'
check "framework restored from archive" '[[ -e "$H/carbon-marker.txt" ]]'
check "force_validate set"            '[[ -e "$H/.cobalt/force_validate" ]]'
check "pending_rollback consumed"     '[[ ! -e "$H/.cobalt/pending_rollback" ]]'
check "depot staging cleaned"         '[[ ! -d "$DEPOT" ]]'

echo "Scenario I: argv quoting + MAP_URL branch"
new_home
run_ep
check "multi-word hostname is ONE arg" 'echo "$OUT" | grep -q "\"My Cool Host\""'
check "procedural branch (worldsize)"  'echo "$OUT" | grep -q "+server.worldsize"'
run_ep MAP_URL="http://example.com/x.map"
check "levelurl branch when MAP_URL"   'echo "$OUT" | grep -q "\"+server.levelurl\",\"http://example.com/x.map\""'
check "no worldsize with MAP_URL"      '! echo "$OUT" | grep -q "+server.worldsize"'

echo "Scenario J: .pteroignore + missing binary guard"
new_home
run_ep
check ".pteroignore created"          '[[ -f "$H/.pteroignore" ]] && grep -q "steamcmd/" "$H/.pteroignore"'
new_home
rm -f "$H/RustDedicated"
run_ep
check "missing RustDedicated -> exit 13" '[[ $RC -eq 13 ]]'

echo "Scenario K: carbon-staging framework install (fake curl; staging has only Debug)"
new_home
# fake curl: 404 everything except Carbon.Linux.Debug.tar.gz, log requested URLs
FAKEBIN="$(mktemp -d)"
CURLLOG="$H/.cobalt/curl.log"
cat > "$FAKEBIN/curl" <<'FAKE'
#!/bin/bash
out=""; url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    http*|https*) url="$1"; shift ;;
    *) shift ;;
  esac
done
echo "$url" >> "$CURLLOG"
if [[ "$url" == *Carbon.Linux.Debug.tar.gz ]]; then
  t="$(mktemp -d)"; mkdir -p "$t/carbon"; echo staging > "$t/carbon/marker"
  tar -czf "$out" -C "$t" carbon; rm -rf "$t"; exit 0
fi
exit 22
FAKE
chmod +x "$FAKEBIN/curl"
OUT="$(env COBALT_HOME="$H" COBALT_WRAPPER="$STUB" PATH="$FAKEBIN:$PATH" CURLLOG="$CURLLOG" \
    AUTO_UPDATE=0 FRAMEWORK_UPDATE=1 VALIDATE=0 FRAMEWORK=carbon-staging \
    PREFLIGHT_PORTCHECK=0 OOM_WATCH=0 DISK_MIN_FREE_MB=0 \
    SERVER_IDENTITY=rust MAP_URL="" STARTUP="$STARTUP_BASE" \
    bash "$EP" 2>&1)"; RC=$?
check "exit 0"                          '[[ $RC -eq 0 ]]'
check "used CarbonCommunity/Carbon repo" 'grep -q "CarbonCommunity/Carbon" "$CURLLOG"'
check "used rustbeta_staging_build tag"  'grep -q "rustbeta_staging_build" "$CURLLOG"'
check "tried Release first"              'head -1 "$CURLLOG" | grep -q "Carbon.Linux.Release.tar.gz"'
check "fell back to Debug"               'grep -q "Carbon.Linux.Debug.tar.gz" "$CURLLOG"'
check "carbon/ extracted"                '[[ -f "$H/carbon/marker" ]]'
check "artifact archived"                'ls "$H/.cobalt/frameworks/"carbon-rustbeta_staging_build-*.tar.gz >/dev/null 2>&1'
check "last_install framework recorded"  'grep -q "carbon-staging" "$H/.cobalt/last_install"'

echo "Scenario L: carbon-staging download fails but existing install is kept"
new_home
mkdir -p "$H/carbon"; echo existing > "$H/carbon/marker"   # pretend Carbon already installed
FAKEBIN2="$(mktemp -d)"
cat > "$FAKEBIN2/curl" <<'FAKE'
#!/bin/bash
exit 22
FAKE
chmod +x "$FAKEBIN2/curl"
OUT="$(env COBALT_HOME="$H" COBALT_WRAPPER="$STUB" PATH="$FAKEBIN2:$PATH" \
    AUTO_UPDATE=0 FRAMEWORK_UPDATE=1 VALIDATE=0 FRAMEWORK=carbon-staging \
    PREFLIGHT_PORTCHECK=0 OOM_WATCH=0 DISK_MIN_FREE_MB=0 \
    SERVER_IDENTITY=rust MAP_URL="" STARTUP="$STARTUP_BASE" \
    bash "$EP" 2>&1)"; RC=$?
check "boots anyway (exit 0)"            '[[ $RC -eq 0 ]]'
check "kept existing install msg"        'echo "$OUT" | grep -q "keeping existing install"'
check "existing carbon untouched"        '[[ "$(cat "$H/carbon/marker")" == "existing" ]]'

echo "Scenario M: wipe custom map URL (single + csv rotation)"
new_home
mkdir -p "$H/server/rust"
printf 'map' > "$H/.cobalt/pending_wipe"
run_ep WIPE_MAP_URL="http://ex/m1.map"
check "single map url written"        '[[ "$(cat "$H/.cobalt/mapurl")" == "http://ex/m1.map" ]]'
check "levelurl in argv"              'echo "$OUT" | grep -q "\"+server.levelurl\",\"http://ex/m1.map\""'
check "no worldsize with map url"     '! echo "$OUT" | grep -q "+server.worldsize"'
# next boot (no wipe) still uses the wiped map
run_ep
check "map url persists next boot"    'echo "$OUT" | grep -q "\"+server.levelurl\",\"http://ex/m1.map\""'
# csv rotation across two wipes
new_home
mkdir -p "$H/server/rust"
printf 'map' > "$H/.cobalt/pending_wipe"; run_ep WIPE_MAP_URL="http://ex/a.map,http://ex/b.map"
M1="$(cat "$H/.cobalt/mapurl")"
printf 'map' > "$H/.cobalt/pending_wipe"; run_ep WIPE_MAP_URL="http://ex/a.map,http://ex/b.map"
M2="$(cat "$H/.cobalt/mapurl")"
check "map url rotates a->b"          '[[ "$M1" == "http://ex/a.map" && "$M2" == "http://ex/b.map" ]]'
# empty WIPE_MAP_URL clears the override (revert to procedural)
printf 'map' > "$H/.cobalt/pending_wipe"; run_ep WIPE_MAP_URL=""
check "empty clears map override"     '[[ ! -f "$H/.cobalt/mapurl" ]]'
check "reverts to procedural"         'echo "$OUT" | grep -q "+server.worldsize"'

echo "Scenario N: Carbon doorstop armed only when carbon installed"
new_home
mkdir -p "$H/carbon/tools" "$H/carbon/managed"
touch "$H/libdoorstop.so" "$H/carbon/managed/Carbon.Preloader.dll"
cat > "$H/carbon/tools/environment.sh" <<EOF
export DOORSTOP_ENABLED=1
export DOORSTOP_TARGET_ASSEMBLY="$H/carbon/managed/Carbon.Preloader.dll"
export LD_PRELOAD="$H/libdoorstop.so"
export LD_LIBRARY_PATH="$H:$H/RustDedicated_Data/Plugins/x86_64"
EOF
run_ep FRAMEWORK=carbon-staging
check "doorstop armed for carbon"       'echo "$OUT" | grep -q "STUB_DOORSTOP.*Carbon.Preloader.dll"'
check "arming logged"                   'echo "$OUT" | grep -q "doorstop environment armed"'
# real DOORSTOP/LD_PRELOAD must NOT leak into the exec env (node stays clean)
check "no raw LD_PRELOAD in exec env"   '! echo "$OUT" | grep -q "STUB_DOORSTOP none.*LD_PRELOAD"'
# carbon selected but not installed -> warn, do not arm
new_home
run_ep FRAMEWORK=carbon-staging
check "warns when carbon missing"       'echo "$OUT" | grep -q "will NOT load"'
check "doorstop not armed if missing"   'echo "$OUT" | grep -q "STUB_DOORSTOP none"'
# vanilla never arms
new_home
run_ep FRAMEWORK=vanilla
check "vanilla does not arm doorstop"   'echo "$OUT" | grep -q "STUB_DOORSTOP none"'

echo ""
echo "Entrypoint tests: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
