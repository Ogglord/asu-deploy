# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Deployment config for the self-hosted ASU (Attended Sysupgrade) server on a Debian 12 VPS. No application code — this repo is compose file + config + bash scripts + systemd units. It ties together two other repos:

- **[Ogglord/asu](https://github.com/Ogglord/asu)** — the FastAPI server image (`ghcr.io/ogglord/asu:latest`) pulled by `podman-compose.yml`.
- **[Ogglord/openwrt-imagebuilder-mt6000](https://github.com/Ogglord/openwrt-imagebuilder-mt6000)** — publishes ImageBuilder containers to `ghcr.io` and `branches.json` to its `releases` branch. ASU fetches both at runtime.

## Common tasks

```bash
# First-time VPS provisioning (as root)
sudo bash bootstrap.sh

# Push updates to an existing VPS (after git pull, as root)
sudo bash deploy.sh

# Run the ASU server locally for development (not on the VPS!)
./dev-asu.sh                                 # needs $ASU_DIR pointing at local asu checkout
```

`bootstrap.sh` is for **fresh** Debian 12 VPSes — installs packages, configures sysctl/containers.conf, creates the `asu` service user with subuid/subgid for rootless podman, sets up cloudflared, then calls `deploy.sh`.

`deploy.sh` is **idempotent** and safe to re-run. It copies files into `/home/asu/asu-server/`, preserves `.env` (never overwritten), rewrites `CONTAINER_SOCKET_PATH` from the current `asu` uid, installs systemd units, pulls container images, restarts services, and runs health checks.

`dev-asu.sh` runs the ASU server **locally** against a podman-started Redis on port 6399. It writes a dev `asu.toml` into `$ASU_DIR` (default `$HOME/repos/asu`) — this is where the generated dev config in the sibling `asu` repo comes from. Don't commit that generated `asu.toml` in the asu repo.

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

Three compose services (`podman-compose.yml`), all on the `asu` user's rootless podman:

- **redis** (`redis-stack-server`) — cache + RQ queue. Published on `127.0.0.1:6379`.
- **server** (`ghcr.io/ogglord/asu:latest`) — FastAPI/uvicorn, published on `127.0.0.1:8000`.
- **worker** — same image, runs `rqworker`. Uses `userns: keep-id` and mounts the host's rootless podman socket (`$CONTAINER_SOCKET_PATH → /var/podman.sock`) so it can spawn sibling ImageBuilder containers on the host runtime. `label=disable` is required on SELinux-enabled hosts for the socket mount.

External access: **cloudflared** tunnel (no open ports). `cloudflared-config.yml` is a template — the `<TUNNEL_UUID>` placeholder is filled in after `cloudflared tunnel create asu-server`.

Systemd unit layout (`systemd/`):
- `asu-server.service` — `podman-compose up` / `down` as the `asu` user.
- `cloudflared.service` — runs the named tunnel.
- `asu-healthcheck.service` + `.timer` — fires every 5 min, calls `healthcheck.sh`, which curls `/json/v1/overview.json` and pings `hc-ping.com/$HC_UUID` (success or `/fail`).

## Config contract

`.env` (template: `.env.example`, **never** committed for real):

| Key | Purpose |
|---|---|
| `REDIS_URL` | `redis://redis:6379` (internal compose DNS) |
| `PUBLIC_PATH` | Public URL (the Cloudflare Tunnel hostname) |
| `BASE_CONTAINER` | `ghcr.io/ogglord/openwrt-imagebuilder` — worker appends `:mediatek-filogic-openwrt-<branch>` |
| `UPSTREAM_URL` | Base URL for package downloads (points at the imagebuilder `releases` branch raw) |
| `BRANCHES_URL` | Points at `branches.json` on the imagebuilder `releases` branch — this is the fork-specific delta (upstream ASU has no equivalent) |
| `HC_UUID` | healthchecks.io UUID |
| `CONTAINER_SOCKET_PATH` | Rewritten by `deploy.sh` to `/run/user/<asu-uid>/podman/podman.sock` |
| `ALLOW_DEFAULTS` | Added by `deploy.sh` if missing, default `0` |

`asu.toml` is mounted read-only into both server and worker containers. It sets `upstream_url`, `base_container`, `branches_url`, and declares `[branches]` empty — the fork's `reload_branches()` fills this from `BRANCHES_URL` at startup.

`BRANCHES.md` documents the historical manual-`BRANCHES`-env schema. It's largely superseded by `BRANCHES_URL`, but the schema section is still the reference for what `branches.json` should contain (the imagebuilder CI writes it). Keep this in sync if the schema evolves.

## Editing notes

- Never edit `/home/asu/asu-server/.env` from this repo — `deploy.sh` explicitly preserves it. Edit in-place on the VPS.
- `deploy.sh` migrates deprecated keys (it mentions `BRANCHES → BRANCHES_URL`); add similar migration blocks if a key is renamed.
- If you change `podman-compose.yml` services, make sure the health-check URL in `healthcheck.sh` (`http://localhost:8000/json/v1/overview.json`) still resolves.
- The `userns: keep-id` + `label=disable` combo on the worker is load-bearing for the socket mount — don't "clean up" either without testing on a SELinux host.
