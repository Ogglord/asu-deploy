# ASU Server for pesa1234/openwrt (MT6000)

Self-hosted [Attended Sysupgrade](https://github.com/openwrt/asu) server for the pesa1234/openwrt custom firmware, targeting the GL.iNet Flint 2 (MT6000).

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

Copy `.env.example` to `.env` and fill in:
- `PUBLIC_PATH` -- your Cloudflare Tunnel domain
- `BASE_CONTAINER` -- your ghcr.io ImageBuilder container name
- `BRANCHES` -- JSON mapping of pesa's published branches
- `HC_UUID` -- healthcheck.io UUID for VPS monitoring

## Updating branches

When pesa publishes a new branch in [MT6000_cust_build](https://github.com/pesa1234/MT6000_cust_build):

1. The ImageBuilder container repo will automatically build a new container on its next weekly run
2. Update the `BRANCHES` JSON in `.env` with the new branch entry
3. Restart: `systemctl restart asu-server`

## Files

```
bootstrap.sh          -- Idempotent VPS provisioning script
podman-compose.yml    -- Service definitions (redis, api, worker)
.env.example          -- Configuration template
cloudflared-config.yml -- Cloudflare Tunnel ingress rules
healthcheck.sh        -- Health check script (called by systemd timer)
systemd/              -- Systemd service and timer units
```
