# asu-server

## Purpose

This repository contains the deployment configuration for a self-hosted [OpenWrt Attended Sysupgrade (ASU)](https://github.com/openwrt/asu) server. It serves custom firmware builds from the [pesa1234/openwrt](https://github.com/pesa1234/openwrt) fork for the **GL.iNet Flint 2 (MT6000)** router.

The ASU server lets the router's LuCI web interface request custom firmware images with user-selected packages, built on demand.

## Architecture

```
[LuCI on Flint 2] --> [Cloudflare Tunnel] --> [ASU API :8000]
                                                    |
                                                [Redis Queue]
                                                    |
                                              [ASU Worker]
                                                    |
                                   [Podman --userns=keep-id: ImageBuilder from ghcr.io]
```

Three containerized services orchestrated with podman-compose:
- **Redis** -- image/job caching and task queue
- **ASU API** (FastAPI/uvicorn) -- REST API that accepts build requests and serves results
- **ASU Worker** (rqworker) -- pulls jobs from Redis, spawns Podman containers with the ImageBuilder to assemble firmware images

External access is provided by a **Cloudflare Tunnel** (no open ports on the VPS).

## Target environment

- **OS**: Debian 12 (Bookworm)
- **Container runtime**: Podman + podman-compose (no Docker)
- **Service user**: `asu` (rootless Podman, requires `/etc/subuid` and `/etc/subgid` entries)
- **Worker containers**: use `--userns=keep-id` and mount the host Podman socket to spawn sibling ImageBuilder containers

## Key configuration

The `.env` file controls server behavior. Important settings:

| Variable | Description |
|---|---|
| `BRANCHES_URL` | URL to `branches.json` published by the imagebuilder CI. ASU fetches this at startup and on each overview request to discover available branches, versions, and targets. |
| `UPSTREAM_URL` | Base URL for package downloads (`pesa1234/MT6000_cust_build` raw GitHub) |
| `BASE_CONTAINER` | Base image name; worker appends `:{target}-{tag}` to pull the right ImageBuilder |
| `HC_UUID` | healthcheck.io UUID for uptime monitoring |

`BRANCHES_URL` points to:
```
https://raw.githubusercontent.com/Ogglord/openwrt-imagebuilder-mt6000/releases/branches.json
```
This file is published automatically by the imagebuilder CI after each successful build. See `BRANCHES.md` for its schema.

## Forked ASU server

This setup uses a **forked ASU image** (`ghcr.io/ogglord/asu:latest`) instead of the upstream `openwrt/asu`. The fork is at [Ogglord/asu](https://github.com/Ogglord/asu) and adds:

1. **`BRANCHES_URL` support** (`asu/util.py` — `reload_branches_from_url()`): when set, ASU fetches `branches.json` from that URL and uses it as the single source of truth for branches, versions, and targets. This replaces the combination of the upstream `.versions.json` and per-version `.targets.json` fetches, neither of which exist in the pesa custom build setup.

The upstream ASU expects these files at `{UPSTREAM_URL}/.versions.json` and `{UPSTREAM_URL}/{path}/.targets.json`. These do not exist in `pesa1234/MT6000_cust_build`, so the upstream image cannot be used as-is.

## Deployment

`bootstrap.sh` provisions a fresh Debian 12 VPS (run once):
1. Installs Podman, podman-compose, passt, cloudflared
2. Configures kernel parameters for Redis
3. Creates `asu` service user, sets up subuid/subgid for rootless Podman, runs `podman system migrate`
4. Calls `deploy.sh` and sets up the Cloudflare Tunnel config

`deploy.sh` updates an existing installation (run after `git pull`):
1. Copies updated scripts and `podman-compose.yml`
2. Installs/reloads systemd units
3. Pulls latest container images (`ghcr.io/ogglord/asu:latest`, etc.)
4. Restarts `asu-server` and `cloudflared`

## Monitoring

- `asu-healthcheck.timer` runs `healthcheck.sh` every 5 minutes
- Checks `GET /api/v1/overview` and pings healthcheck.io with success or failure
- UUID read from `HC_UUID` in `.env`

## Companion repositories

| Repo | Role |
|---|---|
| [Ogglord/openwrt-imagebuilder-mt6000](https://github.com/Ogglord/openwrt-imagebuilder-mt6000) | Builds ImageBuilder containers and publishes `branches.json` to the `releases` branch |
| [Ogglord/asu](https://github.com/Ogglord/asu) | Fork of upstream ASU with `BRANCHES_URL` support, built to `ghcr.io/ogglord/asu:latest` |
| [pesa1234/MT6000_cust_build](https://github.com/pesa1234/MT6000_cust_build) | Hosts firmware package files referenced by `UPSTREAM_URL` |
