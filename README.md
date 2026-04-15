# ASU Deploy

Deployment config for the self-hosted [Attended Sysupgrade](https://github.com/openwrt/asu) server, targeting [pesa1234/openwrt](https://github.com/pesa1234/openwrt) custom firmware for the GL.iNet Flint 2 (MT6000).

> **Related repos:**
>
> | Repo | Purpose |
> |------|---------|
> | [Ogglord/asu](https://github.com/Ogglord/asu) | ASU application (fork of openwrt/asu) -- the FastAPI server and worker |
> | [Ogglord/asu-deploy](https://github.com/Ogglord/asu-deploy) | This repo -- deployment config (compose, config, deploy script) |
> | [Ogglord/openwrt-imagebuilder-mt6000](https://github.com/Ogglord/openwrt-imagebuilder-mt6000) | CI workflows that build ImageBuilder containers from pesa1234's branches |

## Architecture

- **Redis** -- caching and job queue
- **ASU API** -- REST API accepting firmware build requests
- **ASU Worker** -- processes builds by spawning ImageBuilder containers via Podman
- **Cloudflare Tunnel** -- exposes the API without opening ports

The ImageBuilder containers are built separately via GitHub Actions and published to ghcr.io.

## Quick start

1. Provision a fresh Debian 12 VPS
2. Clone this repo
3. Run `sudo bash bootstrap.sh`
4. Follow the printed next steps to configure Cloudflare Tunnel and `.env`

## Configuration

- `asu.toml` -- ASU application config (upstream URL, branches, container image)
- `.env` -- environment variables for compose services
- `podman-compose.yml` -- service definitions (redis, api, worker)

## Files

```
bootstrap.sh          -- Idempotent VPS provisioning script
deploy.sh             -- Deploy/redeploy the stack
podman-compose.yml    -- Service definitions (redis, api, worker)
asu.toml              -- ASU application config
.env                  -- Environment variables
cloudflared-config.yml -- Cloudflare Tunnel ingress rules
healthcheck.sh        -- Health check script (called by systemd timer)
systemd/              -- Systemd service and timer units
```
