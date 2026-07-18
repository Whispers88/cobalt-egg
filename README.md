# Cobalt Egg 2.0

Rust Dedicated Server image + egg for Pterodactyl.
Image: `ghcr.io/whispers88/cobalt-egg:latest` · Egg: `egg-cobalt88-v2.json`

**2.0:** version pin/rollback via Steam manifests · framework/branch decoupled ·
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
| `.telemetry` | game CPU/RSS, loadavg, disk |

Rollback is **staged as a flag and applied at boot** — the only safe mutation
point in the container lifecycle; `.rollback` then restart.

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

## Framework and branch are independent

`FRAMEWORK` (which mod loader) and `STEAM_BRANCH` (which Rust game branch) are
separate. The framework channel follows the branch:

| `STEAM_BRANCH` | Rust game | Carbon tag | Oxide |
|---|---|---|---|
| *(empty)* | public | `production_build` | release |
| `staging` | `-beta staging` | `rustbeta_staging_build` | staging |
| `aux01` | `-beta aux01` | `rustbeta_aux01_build` | release |
| `aux02` | `-beta aux02` | `rustbeta_aux02_build` | release |

So `FRAMEWORK=carbon` + `STEAM_BRANCH=staging` = Carbon on the Rust staging
branch. `FRAMEWORK=vanilla` + `STEAM_BRANCH=staging` = plain staging server.
For anything the branch mapping doesn't cover (e.g. Carbon edge), set
`CUSTOM_FRAMEWORK_URL` to a direct `.zip`/`.tar.gz` (it overrides `FRAMEWORK`;
keep `FRAMEWORK=carbon` so doorstop is still armed).

## Key variables

| Var | Default | Notes |
|---|---|---|
| `FRAMEWORK` | `carbon` | `vanilla` / `oxide` / `carbon` / `carbon-minimal` |
| `STEAM_BRANCH` | *(empty)* | Rust game branch: empty=public, `staging`, `aux01`, `aux02` |
| `CUSTOM_FRAMEWORK_URL` | — | direct framework archive URL; overrides `FRAMEWORK` |
| `AUTO_UPDATE` | `1` | app_update on boot (ignored while pinned) |
| `DOWNLOADER` | `steamcmd` | `steamcmd` or `depotdownloader` (SteamRE, self-contained, downloads straight into the server dir) |
| `VALIDATE` | `0` | full checksum costs minutes; auto-forced once after rollback/branch change |
| `GAMEMODE` | `vanilla` | `vanilla`/`softcore`/`hardcore` (`in:` rule — dropdown on Pelican or with the dropdown addon, validated text box on stock Ptero) |
| `SHUTDOWN_TIMEOUT_SEC` | `60` | save time before force-kill; big maps need it |
| `UPDATE_CHECK_INTERVAL_SEC` | `3600` | update-available warning; 0 = off |
| `SERVER_IDENTITY` | `rust` | saves live in `server/<identity>/` |
| `DISK_MIN_FREE_MB` / `DISK_ENFORCE` / `PREFLIGHT_PORTCHECK` / `OOM_WATCH` | | boot preflight guards |
| `CONSOLE_COLORS` | *(empty)* | custom console palette — comma hex `normal,error,warn,oxide,carbon,rcon` (blank slots keep defaults) or `name=hex` pairs; truecolor |

A `.pteroignore` is written on first boot so panel backups skip `steamcmd/`,
`Steam/`, logs, and rollback staging (saves GB per backup).

## Tests

```
bash test/run-tests.sh
```

No Docker needed: `test/mock-rust.js` fakes RustDedicated (writes the -logfile,
serves real RFC6455 WebRCON, broadcasts noise the wrapper must suppress) and
`test/fake-steamcmd.js` fakes depot downloads. 64 checks across wrapper e2e +
entrypoint rollback/pin/branch/doorstop/argv scenarios.

## Still needs verification on a real Linux box

- `steamcmd +download_depot` content layout & whether months-old manifests
  still download anonymously (manifest request codes).
- Real Rust WebRCON handshake vs the native Node client (mock is RFC-faithful,
  Rust is the authority).
- Exact Rust Steam beta branch names (`staging` / `aux01` / `aux02`) as Facepunch
  currently publishes them, for the `-beta` flag.
