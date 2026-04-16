#!/usr/bin/env bash
# dev-asu.sh — bring up the ASU stack in dev mode against the vendored
# ./asu submodule, with live code reload and an isolated Redis DB.
#
# Dev and prod share the same user (`asu`), podman daemon, network, and
# ports. The only separation is Redis DB number (prod=0, dev=1), which
# lets us FLUSHDB freely without touching prod.
#
# Run this as your regular user (e.g. `ogge`), NOT as root or `asu`.
# It uses `sudo` to stop the prod systemd unit and to invoke all podman
# operations as `asu`. Requires passwordless sudo for your user.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ASU_USER="asu"
ASU_UID="$(id -u "$ASU_USER" 2>/dev/null || echo "")"
SOCKET_PATH="/run/user/${ASU_UID}/podman/podman.sock"

as_asu() {
  sudo -u "$ASU_USER" --preserve-env=PATH -- "$@"
}

compose() {
  as_asu podman-compose -f podman-compose.yml -f podman-compose.dev.yml "$@"
}

# --- Preflight ---
if [[ "$(id -u)" -eq 0 ]]; then
  echo "Error: run this as your regular user, not root." >&2
  exit 1
fi
if [[ "$(id -un)" == "$ASU_USER" ]]; then
  echo "Error: run this as your own user, not '$ASU_USER'." >&2
  echo "The script will invoke podman as '$ASU_USER' via sudo." >&2
  exit 1
fi
if [[ -z "$ASU_UID" ]]; then
  echo "Error: user '$ASU_USER' does not exist. Run bootstrap.sh first." >&2
  exit 1
fi
if ! sudo -n -u "$ASU_USER" true 2>/dev/null; then
  echo "Error: need passwordless sudo to run commands as '$ASU_USER'." >&2
  echo "Add a sudoers rule for your user, e.g.:" >&2
  echo "  $(id -un) ALL=(ALL) NOPASSWD: ALL" >&2
  exit 1
fi
if [[ ! -f "$SCRIPT_DIR/asu/pyproject.toml" ]]; then
  echo "Error: asu submodule not initialized. Run:" >&2
  echo "  git submodule update --init --recursive" >&2
  exit 1
fi
if ! as_asu test -r "$SCRIPT_DIR/podman-compose.yml"; then
  echo "Error: user '$ASU_USER' cannot read $SCRIPT_DIR." >&2
  echo "Grant read access, e.g.:" >&2
  echo "  chmod o+rx $(dirname "$SCRIPT_DIR") && chmod -R o+rX $SCRIPT_DIR" >&2
  exit 1
fi
# Check the socket as $ASU_USER — /run/user/$ASU_UID is 700-owned by asu,
# so the invoking user can't stat the socket path directly.
if ! as_asu test -S "$SOCKET_PATH"; then
  echo "Error: podman socket not found at $SOCKET_PATH" >&2
  echo "Ensure '$ASU_USER' has linger enabled and podman.socket is active:" >&2
  echo "  sudo loginctl enable-linger $ASU_USER" >&2
  echo "  sudo -u $ASU_USER env XDG_RUNTIME_DIR=/run/user/$ASU_UID \\" >&2
  echo "    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$ASU_UID/bus \\" >&2
  echo "    systemctl --user enable --now podman.socket" >&2
  exit 1
fi

# --- Ensure .env has the right socket path for asu's podman ---
ENV_FILE="$SCRIPT_DIR/.env"
touch "$ENV_FILE"
if grep -q '^CONTAINER_SOCKET_PATH=' "$ENV_FILE"; then
  sed -i "s|^CONTAINER_SOCKET_PATH=.*|CONTAINER_SOCKET_PATH=${SOCKET_PATH}|" "$ENV_FILE"
else
  echo "CONTAINER_SOCKET_PATH=${SOCKET_PATH}" >> "$ENV_FILE"
fi

# --- Stop prod systemd unit (frees ports 8000/6379 under asu) ---
if systemctl is-active --quiet asu-server 2>/dev/null; then
  echo "Stopping prod asu-server.service..."
  sudo systemctl stop asu-server
fi

# --- Reset dev Redis DB + orphan build containers (all under asu's podman) ---
# Tear down any leftover dev containers first — podman-compose isn't
# consistent about reusing partially-running pods across interrupted runs.
echo "Resetting dev state..."
compose down 2>/dev/null || true
compose up -d redis

# podman-compose ps -q doesn't accept a service filter, so look up by name.
# The project name defaults to the compose dir basename (asu-deploy).
PROJECT="$(basename "$SCRIPT_DIR")"
REDIS_CID=""
for _ in $(seq 1 20); do
  REDIS_CID="$(as_asu podman ps --filter "name=${PROJECT}_redis" -q 2>/dev/null | head -1 || true)"
  if [[ -n "$REDIS_CID" ]] && as_asu podman exec "$REDIS_CID" redis-cli PING >/dev/null 2>&1; then
    break
  fi
  REDIS_CID=""
  sleep 0.5
done

if [[ -z "$REDIS_CID" ]]; then
  echo "Error: redis container did not come up." >&2
  exit 1
fi

as_asu podman exec "$REDIS_CID" redis-cli -n 1 FLUSHDB >/dev/null
echo "  Redis DB 1 flushed"

ORPHANS="$(as_asu podman ps -a --filter network=asu-build -q 2>/dev/null || true)"
if [[ -n "$ORPHANS" ]]; then
  echo "  Removing orphan build containers: $(echo "$ORPHANS" | wc -l)"
  echo "$ORPHANS" | xargs -r sudo -u "$ASU_USER" podman rm -f >/dev/null
fi

# --- Rebuild asu-dev image when submodule is dirty or image is missing ---
if [[ -n "$(git -C "$SCRIPT_DIR/asu" status --porcelain)" ]] \
   || ! as_asu podman image exists asu-dev:latest 2>/dev/null; then
  echo "Building asu-dev image from ./asu..."
  compose build
fi

# --- Print resolved config for transparency ---
# Parse .env without sourcing it (to avoid surprises from quoting/commands).
env_val() { grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true; }
redact() { [[ -n "$1" ]] && echo "<set>" || echo "<unset>"; }

echo ""
echo "=== Config ==="
echo "  Run user:                $(id -un) (uid=$(id -u))"
echo "  Podman user:             $ASU_USER (uid=$ASU_UID)"
echo "  Repo:                    $SCRIPT_DIR"
echo "  Compose:                 podman-compose.yml + podman-compose.dev.yml"
echo "  Build context:           ./asu (submodule)"
echo "  Live-reload mount:       ./asu/asu -> /app/asu:ro"
echo ""
echo "  --- from .env ($ENV_FILE) ---"
echo "  REDIS_URL (base):        $(env_val REDIS_URL)"
echo "  PUBLIC_PATH:             $(env_val PUBLIC_PATH)"
echo "  BASE_CONTAINER:          $(env_val BASE_CONTAINER)"
echo "  UPSTREAM_URL:            $(env_val UPSTREAM_URL)"
echo "  BRANCHES_URL:            $(env_val BRANCHES_URL)"
echo "  CONTAINER_SOCKET_PATH:   $(env_val CONTAINER_SOCKET_PATH)"
echo "  ALLOW_DEFAULTS:          $(env_val ALLOW_DEFAULTS)"
echo "  HC_UUID:                 $(redact "$(env_val HC_UUID)")"
echo ""
echo "  --- overrides from podman-compose.dev.yml ---"
echo "  server REDIS_URL:        redis://redis:6379/1"
echo "  worker REDIS_URL:        redis://redis:6379/1"
echo "  LOG_LEVEL:               DEBUG"
echo ""

# --- Start stack in the foreground (Ctrl+C brings it down) ---
echo "=== Starting dev stack (as user: $ASU_USER) ==="
echo "    Server: http://localhost:8000    (docs: /docs)"
echo "    Redis:  db=1 (prod=db=0)"
echo "    Smoke test:  ./smoke-test.sh"
echo "    Press Ctrl+C to stop"
echo ""
exec sudo -u "$ASU_USER" --preserve-env=PATH -- \
  podman-compose -f podman-compose.yml -f podman-compose.dev.yml up
