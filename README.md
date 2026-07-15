# Cobalt Egg 2.0

Rust Dedicated Server image + egg for Pterodactyl.
Image: `ghcr.io/whispers88/cobalt-egg:latest` · Egg: `egg-cobalt88-v2.json`

**2.0:** version pin/rollback via Steam manifests · wipe management ·
logfile-read + WebRCON-send console (the PTY/stdin machinery is gone) ·
zero-dependency wrapper (Node 22 native WebSocket).

## Console commands

| Command | Action |
|---|---|
| *(anything)* / `rcon: <x>` | send via WebRCON, response printed |
| `! <sh>` | run shell in the container |
| `.help` | list commands |
| `.version` | installed build, framework, pin state, catalog |
| `.pin [buildid]` | freeze updates on current (or given) build |
| `.unpin` | resume updates at next restart |
| `.rollback <buildid\|last>` | download old build now, **applied at next restart** |
| `.wipe map` | stage map wipe (applies at next restart) |
| `.wipe full confirm` | stage map+blueprint wipe (token required) |
| `.telemetry` | game CPU/RSS, loadavg, disk |
| `.stdin <x>` | write to game stdin (needs `ALLOW_STDIN=1`) |

Destructive operations are **staged as flags and applied at boot** — the only
safe mutation point in the container lifecycle. `.rollback`/`.wipe` then restart.

## Version pin & rollback

- Every successful update records `{buildid, depot manifests, framework version}`
  into `.cobalt/versions.json` and archives the framework artifact (~10–50 MB)
  into `.cobalt/frameworks/` — Carbon rolling tags get overwritten upstream, so
  historical re-download is unreliable; the archive isn't.
- `.pin` skips SteamCMD entirely on boot (faster starts, no surprise updates).
  Caveat: clients force-update — a pinned server goes protocol-incompatible
  within hours-to-days. Pin is a patch-day tool.
- `.rollback <build>` re-downloads that build's exact depot manifests via
  `steamcmd download_depot` (needs ~10 GB free) while the server keeps running,
  then applies at next boot: game files from Steam, framework from the local
  archive, `force_validate` set so the next unpinned update reconciles the acf.
- An hourly watcher warns in console when Facepunch ships a new build
  (`UPDATE_CHECK_INTERVAL_SEC`, 0 to disable).

## Scheduled wipes (no cron in the egg — use Pterodactyl Schedules)

Create a Schedule (e.g. first Thursday, 19:00):
1. Task 1 — **Send command**: `.wipe map` (or `.wipe full confirm`)
2. Task 2 — **Send power action**: Restart (small delay after task 1)

The boot consumes the flag, wipes `server/<identity>/`, and (if `WIPE_NEW_SEED`
is `random` or a `csv,rotation,list`) swaps the seed.

## Key variables

| Var | Default | Notes |
|---|---|---|
| `FRAMEWORK` | `carbon` | vanilla, oxide[-staging], carbon[-edge/-staging/-aux1/-aux2][-minimal] |
| `AUTO_UPDATE` | `1` | SteamCMD app_update on boot (ignored while pinned) |
| `VALIDATE` | `0` | full checksum costs minutes; auto-forced once after rollback |
| `PIN_BUILD` | — | seed a pin from the panel |
| `WIPE_NEW_SEED` | `keep` | `random` or `seed,list,rotation` |
| `SHUTDOWN_TIMEOUT_SEC` | `60` | save time before force-kill; big maps need it |
| `UPDATE_CHECK_INTERVAL_SEC` | `3600` | update-available warning; 0 = off |
| `SERVER_IDENTITY` | `rust` | wipes target `server/<identity>/` |
| `DISK_MIN_FREE_MB` / `DISK_ENFORCE` / `PREFLIGHT_PORTCHECK` / `OOM_WATCH` | | boot preflight guards |

A `.pteroignore` is written on first boot so panel backups skip `steamcmd/`,
`Steam/`, logs, and rollback staging (saves GB per backup).

## Tests

```
bash test/run-tests.sh
```

No Docker needed: `test/mock-rust.js` fakes RustDedicated (writes the -logfile,
serves real RFC6455 WebRCON, broadcasts noise the wrapper must suppress) and
`test/fake-steamcmd.js` fakes depot downloads. 56 checks across wrapper e2e +
entrypoint wipe/rollback/pin/argv scenarios.

## Still needs verification on a real Linux box

- `steamcmd +download_depot` content layout & whether months-old manifests
  still download anonymously (manifest request codes).
- Real Rust WebRCON handshake vs the native Node client (mock is RFC-faithful,
  Rust is the authority).
- Exact wipe filenames on the current build (`player.*.db` schema suffix).
