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
echo "[1/5] Copying files to $ASU_HOME..."
mkdir -p "$ASU_HOME"
for f in podman-compose.yml healthcheck.sh asu.toml; do
  cp "$SCRIPT_DIR/$f" "$ASU_HOME/"
done
chmod +x "$ASU_HOME/healthcheck.sh"
chown -R asu:asu "$ASU_HOME"

# --- Ensure required env vars are present in .env ---
echo "[2/5] Updating .env with required settings..."
ENV_FILE="$ASU_HOME/.env"

# Helper: add key=value only if the key is not already present
add_env_if_missing() {
  local key="$1" val="$2"
  if ! grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    echo "${key}=${val}" >> "$ENV_FILE"
    echo "  added ${key}"
  fi
}

# CONTAINER_SOCKET_PATH must always reflect the actual host socket path (uid may change)
ASU_UID=$(id -u asu)
SOCKET_PATH="/run/user/${ASU_UID}/podman/podman.sock"
if grep -q "^CONTAINER_SOCKET_PATH=" "$ENV_FILE" 2>/dev/null; then
  sed -i "s|^CONTAINER_SOCKET_PATH=.*|CONTAINER_SOCKET_PATH=${SOCKET_PATH}|" "$ENV_FILE"
else
  echo "CONTAINER_SOCKET_PATH=${SOCKET_PATH}" >> "$ENV_FILE"
  echo "  added CONTAINER_SOCKET_PATH=${SOCKET_PATH}"
fi
# Whether to allow custom UCI defaults scripts on first boot
add_env_if_missing "ALLOW_DEFAULTS" "0"

# Migrate PUBLIC_PATH from URL (old template) to filesystem path. ASU's
# public_path setting is a Path — a URL produces /app/https:/<host>/store.
if grep -qE '^PUBLIC_PATH=https?://' "$ENV_FILE" 2>/dev/null; then
  sed -i 's|^PUBLIC_PATH=.*|PUBLIC_PATH=/app/public|' "$ENV_FILE"
  echo "  migrated PUBLIC_PATH (URL → /app/public)"
fi
add_env_if_missing "PUBLIC_PATH" "/app/public"

chown asu:asu "$ENV_FILE"

# Ensure the firmware-store bind source exists and is owned by asu
# (server and worker mount /tmp/asu-public-data:/app/public). systemd
# also recreates this on service start via ExecStartPre, but do it here
# too so `podman-compose up` run manually right after deploy.sh works.
install -d -o asu -g asu -m 755 /tmp/asu-public-data

# --- Systemd units ---
echo "[3/5] Installing systemd units..."
cp "$SCRIPT_DIR"/systemd/*.service /etc/systemd/system/
cp "$SCRIPT_DIR"/systemd/*.timer /etc/systemd/system/
sed -i "s/@ASU_UID@/${ASU_UID}/g" /etc/systemd/system/asu-server.service
systemctl daemon-reload
systemctl enable asu-server cloudflared asu-healthcheck.timer

# --- Pull latest container images ---
echo "[4/5] Pulling latest container images..."
sudo -u asu podman-compose -f "$ASU_HOME/podman-compose.yml" pull

# --- Restart running services to pick up changes ---
echo "[5/5] Restarting services..."
for svc in asu-server cloudflared; do
  if systemctl is-active --quiet "$svc"; then
    systemctl restart "$svc"
    echo "  restarted $svc"
  else
    echo "  $svc is not running, starting it..."
    systemctl start "$svc"
  fi
done

echo ""
echo "=== Health checks ==="
echo "Waiting for server to become ready..."
max_wait=60
interval=3
elapsed=0
until curl -o /dev/null -fsS -m 5 http://localhost:8000/ 2>/dev/null; do
  if [[ $elapsed -ge $max_wait ]]; then
    echo "  Server did not respond within ${max_wait}s — check 'journalctl -u asu-server'"
    exit 1
  fi
  sleep $interval
  elapsed=$((elapsed + interval))
done

BASE=http://localhost:8000
all_ok=true
for path in "/" "/json/v1/overview.json" "/static/style.css"; do
  http_code=$(curl -o /dev/null -sS -m 10 -w "%{http_code}" "$BASE$path" 2>/dev/null); rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "  FAIL (connection error)  $path"
    all_ok=false
  elif [[ "$http_code" =~ ^2 ]]; then
    echo "  OK   $http_code  $path"
  else
    echo "  FAIL $http_code  $path"
    all_ok=false
  fi
done

if $all_ok; then
  echo ""
  echo "=== Deploy complete ==="
else
  echo ""
  echo "=== Deploy complete (with health check failures — check 'journalctl -u asu-server' for logs) ==="
fi
