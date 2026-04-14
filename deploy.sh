#!/usr/bin/env bash
# Deploy updated scripts and systemd units to an existing installation.
# Safe to re-run at any time. Does not overwrite .env, but migrates
# deprecated keys (BRANCHES → BRANCHES_URL).
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASU_HOME=/home/asu/asu-server

echo "=== Deploying ASU server files ==="

# --- Scripts and compose file ---
echo "[1/4] Copying files to $ASU_HOME..."
mkdir -p "$ASU_HOME"
for f in podman-compose.yml healthcheck.sh; do
  cp "$SCRIPT_DIR/$f" "$ASU_HOME/"
done
chmod +x "$ASU_HOME/healthcheck.sh"
chown -R asu:asu "$ASU_HOME"

# --- Systemd units ---
echo "[2/4] Installing systemd units..."
cp "$SCRIPT_DIR"/systemd/*.service /etc/systemd/system/
cp "$SCRIPT_DIR"/systemd/*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable asu-server cloudflared asu-healthcheck.timer

# --- Pull latest container images ---
echo "[3/4] Pulling latest container images..."
sudo -u asu podman-compose -f "$ASU_HOME/podman-compose.yml" pull

# --- Restart running services to pick up changes ---
echo "[4/4] Restarting services..."
for svc in asu-server cloudflared; do
  if systemctl is-active --quiet "$svc"; then
    systemctl restart "$svc"
    echo "  restarted $svc"
  else
    echo "  $svc is not running, skipping restart"
  fi
done

echo ""
echo "=== Deploy complete ==="
