# CLAUDE.md

Guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Deployment config for self-hosted ASU (Attended Sysupgrade) server on Debian 12 VPS. No application code — repo is compose file + config + bash scripts + systemd units. Ties two other repos:

- **[Ogglord/asu](https://github.com/Ogglord/asu)** — FastAPI server image (`ghcr.io/ogglord/asu:latest`) pulled by `podman-compose.yml`.
- **[Ogglord/openwrt-imagebuilder-mt6000](https://github.com/Ogglord/openwrt-imagebuilder-mt6000)** — publishes ImageBuilder containers to `ghcr.io` and `branches.json` to its `releases` branch. ASU fetches both at runtime.

## Common tasks

```bash
# First-time VPS provisioning (as root)
sudo bash bootstrap.sh

# Push updates to an existing VPS (after git pull, as root)
sudo bash deploy.sh

# Dev stack against the ./asu submodule with live reload
./dev-asu.sh

# Probe every read-only endpoint (run after any code change)
./smoke-test.sh [base-url]
```

`bootstrap.sh` — **fresh** Debian 12 VPS only. Installs packages, configures sysctl/containers.conf, creates `asu` service user with subuid/subgid for rootless podman, sets up cloudflared, then calls `deploy.sh`.

`deploy.sh` — **idempotent**, safe to re-run. Copies files into `/home/asu/asu-server/`, preserves `.env` (never overwritten), rewrites `CONTAINER_SOCKET_PATH` from current `asu` uid, installs systemd units, pulls container images, restarts services, runs health checks.

`dev-asu.sh` — brings up compose stack against `./asu` submodule with live code reload. Isolates dev state on Redis DB 1 (prod = DB 0), flushes on every run so stale worker-cache never carries over. Stops `asu-server.service` first (ports 8000/6379 shared with prod).

**Runs as regular user with passwordless sudo (e.g. `ogge`), not `asu` or `root`.** Invokes all podman ops as `asu` via `sudo -u asu` so dev containers land in same rootless-podman namespace as prod (shared `asu-build` network, same socket path, orphan cleanup works across both). Preflight rejects root and `asu`, verifies sudoer can `sudo -u asu` passwordless, checks `asu` user can read repo, rewrites `CONTAINER_SOCKET_PATH` in repo-local `.env` to point at `asu`'s rootless socket.

## After any code change — run the smoke test

```bash
./smoke-test.sh                          # default: http://localhost:8000
./smoke-test.sh https://asu.example.com  # against the prod tunnel
```

`smoke-test.sh` probes every read-only endpoint — HTML index/stats, `/docs`, `/static/`, `/json/v1/{latest,branches,overview}.json`, and parameterized `/api/v1/revision/...` derived from current `branches.json` (probe doesn't rot as versions change). Does **not** enqueue builds. Exits non-zero on failure. Requires `curl` and `jq`.

Run after every meaningful change — compose edit, asu submodule bump, `.env` tweak, or `deploy.sh` on VPS. CI-style: `./smoke-test.sh && echo ok`.

## Stack layout

```
[LuCI on Flint 2] → [Cloudflare Tunnel] → [ASU API :8000]
                                               ↓
                                          [Redis Queue]
                                               ↓
                                         [ASU Worker]
                                               ↓
                              [podman (userns=keep-id) → ImageBuilder container]
```

Three compose services (`podman-compose.yml`), all on `asu` user's rootless podman:

- **redis** (`redis-stack-server`) — cache + RQ queue. Published on `127.0.0.1:6379`.
- **server** (`ghcr.io/ogglord/asu:latest`) — FastAPI/uvicorn, published on `127.0.0.1:8000`.
- **worker** — same image, runs `rqworker`. Uses `userns: keep-id`, mounts host rootless podman socket (`$CONTAINER_SOCKET_PATH → /var/podman.sock`) to spawn sibling ImageBuilder containers on host runtime. `label=disable` required on SELinux hosts for socket mount.

External access: **cloudflared** tunnel (no open ports). `cloudflared-config.yml` is template — `<TUNNEL_UUID>` filled after `cloudflared tunnel create asu-server`.

Systemd unit layout (`systemd/`):
- `asu-server.service` — `podman-compose up` / `down` as `asu` user.
- `cloudflared.service` — runs named tunnel.
- `asu-healthcheck.service` + `.timer` — fires every 5 min, calls `healthcheck.sh`, curls `/json/v1/overview.json`, pings `hc-ping.com/$HC_UUID` (success or `/fail`).

## Config contract

`.env` (template: `.env.example`, **never** committed for real):

| Key | Purpose |
|---|---|
| `REDIS_URL` | `redis://redis:6379` (internal compose DNS) |
| `PUBLIC_PATH` | Filesystem path *inside container* for firmware store (default `/app/public`). Shared volume — `server` and `worker` see same dir. Not URL — Cloudflare hostname configured in `cloudflared-config.yml`. |
| `BASE_CONTAINER` | `ghcr.io/ogglord/openwrt-imagebuilder` — worker appends `:mediatek-filogic-openwrt-<branch>` |
| `UPSTREAM_URL` | Base URL for package downloads (points at imagebuilder `releases` branch raw) |
| `BRANCHES_URL` | Points at `branches.json` on imagebuilder `releases` branch — fork-specific delta (upstream ASU has no equivalent) |
| `HC_UUID` | healthchecks.io UUID |
| `CONTAINER_SOCKET_PATH` | Rewritten by `deploy.sh` to `/run/user/<asu-uid>/podman/podman.sock` |
| `ALLOW_DEFAULTS` | Added by `deploy.sh` if missing, default `0` |

`asu.toml` mounted read-only into both server and worker. Sets `upstream_url`, `base_container`, `branches_url`, declares `[branches]` empty — fork's `reload_branches()` fills from `BRANCHES_URL` at startup.

`BRANCHES.md` documents historical manual-`BRANCHES`-env schema. Largely superseded by `BRANCHES_URL`, but schema section still reference for what `branches.json` should contain (imagebuilder CI writes it). Keep in sync if schema evolves.

## Editing notes

- Never edit `/home/asu/asu-server/.env` from this repo — `deploy.sh` explicitly preserves it. Edit in-place on VPS.
- `deploy.sh` migrates deprecated keys (mentions `BRANCHES → BRANCHES_URL`); add similar migration blocks for renamed keys.
- If `podman-compose.yml` services change, verify health-check URL in `healthcheck.sh` (`http://localhost:8000/json/v1/overview.json`) still resolves.
- `userns: keep-id` + `label=disable` on worker is load-bearing for socket mount — don't "clean up" either without testing on SELinux host.