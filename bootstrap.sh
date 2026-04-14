#!/usr/bin/env bash
set -euo pipefail

echo "=== ASU Server Bootstrap for Debian 12 ==="

if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- System packages ---
echo "[1/7] Installing system packages..."
apt-get update
apt-get install -y podman podman-compose passt curl jq

# --- Sysctl for Redis ---
echo "[2/7] Configuring kernel parameters..."
cat > /etc/sysctl.d/99-asu.conf << 'EOF'
vm.overcommit_memory = 1
net.core.somaxconn = 512
EOF
sysctl -p /etc/sysctl.d/99-asu.conf

# --- Podman: use nftables firewall driver ---
mkdir -p /etc/containers
cat > /etc/containers/containers.conf << 'EOF'
[network]
firewall_driver = "nftables"
EOF

# --- Cloudflared ---
echo "[3/7] Installing cloudflared..."
if ! command -v cloudflared &>/dev/null; then
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    -o /usr/share/keyrings/cloudflare-main.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared bookworm main" \
    > /etc/apt/sources.list.d/cloudflared.list
  apt-get update && apt-get install -y cloudflared
else
  echo "  cloudflared already installed"
fi

# --- Create service user ---
echo "[4/7] Setting up service user..."
if ! id asu &>/dev/null; then
  useradd -m -s /bin/bash asu
fi
loginctl enable-linger asu

# Required for rootless Podman image unpacking
if ! grep -q '^asu:' /etc/subuid; then
  usermod --add-subuids 100000-165535 --add-subgids 100000-165535 asu
fi
su -l asu -c 'podman system migrate'

# --- Deploy config files, scripts, and systemd units ---
echo "[5/7] Deploying configuration files..."
ASU_HOME=/home/asu/asu-server

# Copy .env only if it doesn't exist (don't overwrite user edits)
if [[ ! -f "$ASU_HOME/.env" ]]; then
  mkdir -p "$ASU_HOME"
  cp "$SCRIPT_DIR/.env.example" "$ASU_HOME/.env"
  echo "  Created .env from template -- edit it with your settings"
else
  echo "  .env already exists, skipping (won't overwrite)"
fi

bash "$SCRIPT_DIR/deploy.sh"

# --- Cloudflare Tunnel config ---
echo "[6/7] Setting up Cloudflare Tunnel config..."
mkdir -p /home/asu/.cloudflared
if [[ -f "$SCRIPT_DIR/cloudflared-config.yml" ]]; then
  cp "$SCRIPT_DIR/cloudflared-config.yml" /home/asu/.cloudflared/config.yml
fi
chown -R asu:asu /home/asu/.cloudflared

echo "[7/7] Systemd units handled by deploy.sh"

echo ""
echo "=== Bootstrap complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit /home/asu/asu-server/.env with your settings"
echo "  2. sudo -u asu cloudflared tunnel login"
echo "  3. sudo -u asu cloudflared tunnel create asu-server"
echo "  4. Edit /home/asu/.cloudflared/config.yml with your tunnel UUID"
echo "  5. cloudflared tunnel route dns asu-server asu.yourdomain.com"
echo "  6. systemctl start asu-server cloudflared asu-healthcheck.timer"
