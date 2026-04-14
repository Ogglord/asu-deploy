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
- **Worker containers**: use `--userns=keep-id` and mount the host Podman socket to spawn sibling ImageBuilder containers

## Key configuration

The `.env` file controls the server behavior. The most important setting is `BRANCHES`, a JSON object that:
- Maps each pesa firmware branch to a display name
- Points to the correct package directory in [pesa1234/MT6000_cust_build](https://github.com/pesa1234/MT6000_cust_build) via raw GitHub URLs
- Maps `mediatek/filogic` target to a container tag suffix so the worker pulls the right ImageBuilder container from ghcr.io

The `BRANCHES` config must be updated manually when pesa publishes new releases.

## Deployment

`bootstrap.sh` is an idempotent script that provisions a fresh Debian 12 VPS:
1. Installs Podman, podman-compose, passt, cloudflared
2. Configures kernel parameters for Redis
3. Creates a dedicated `asu` service user with lingering enabled
4. Deploys config files and systemd units
5. Prints post-install steps for Cloudflare Tunnel setup

## Monitoring

- A systemd timer runs `healthcheck.sh` every 5 minutes
- It checks the API endpoint (`/api/v1/revision`) and pings healthcheck.io with success or failure
- The healthcheck UUID is read from `HC_UUID` in `.env`

## Companion repository

The ImageBuilder containers consumed by this server are built in [`openwrt-imagebuilder-mt6000`](../openwrt-imagebuilder-mt6000/).
