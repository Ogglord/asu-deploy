#!/usr/bin/env bash
# dev-asu.sh — bring up the ASU stack in dev mode against the vendored
# ./asu submodule, with live code reload and an isolated Redis DB.
#
# Dev and prod share the same compose file, container runtime, and ports.
# The only separation is Redis DB number (prod=0, dev=1), which lets us
# FLUSHDB freely without touching prod.
#
# Requirements: podman, podman-compose. Run as the user that owns the
# rootless podman socket used by the prod stack (typically `asu` on the
# VPS, or your own user on a laptop).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE=(podman-compose -f podman-compose.yml -f podman-compose.dev.yml)

# --- Verify submodule is present ---
if [[ ! -f "$SCRIPT_DIR/asu/pyproject.toml" ]]; then
  echo "Error: asu submodule not initialized. Run:"
  echo "  git submodule update --init --recursive"
  exit 1
fi

# --- Stop prod systemd unit if it's running (ports would clash) ---
if systemctl is-active --quiet asu-server 2>/dev/null; then
  echo "Stopping prod asu-server.service..."
  sudo systemctl stop asu-server
fi

# --- Reset dev Redis DB + orphan build containers ---
echo "Resetting dev state..."

# Bring Redis up first (idempotent) so we can flush it before starting workers.
"${COMPOSE[@]}" up -d redis

# Wait for Redis to accept connections (up to 10s)
for _ in $(seq 1 20); do
  if podman exec "$("${COMPOSE[@]}" ps -q redis)" redis-cli PING >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

REDIS_CID=$("${COMPOSE[@]}" ps -q redis)
podman exec "$REDIS_CID" redis-cli -n 1 FLUSHDB >/dev/null
echo "  Redis DB 1 flushed"

# Kill orphan ImageBuilder containers from previous dev/prod runs.
# They attach to the asu-build network; nothing else on this host does.
ORPHANS=$(podman ps -a --filter network=asu-build -q 2>/dev/null || true)
if [[ -n "$ORPHANS" ]]; then
  echo "  Removing orphan build containers: $(echo "$ORPHANS" | wc -l)"
  echo "$ORPHANS" | xargs -r podman rm -f >/dev/null
fi

# Remove the old standalone dev Redis from the previous dev-asu.sh version.
if podman container exists dev-asu-redis 2>/dev/null; then
  echo "  Removing legacy dev-asu-redis container"
  podman rm -f dev-asu-redis >/dev/null
fi

# --- Build image from submodule if code or pyproject.toml changed ---
# podman-compose only rebuilds when asked; let git dirty-state decide.
if [[ -n "$(git -C "$SCRIPT_DIR/asu" status --porcelain)" ]] \
   || ! podman image exists asu-dev:latest 2>/dev/null; then
  echo "Building asu-dev image from ./asu..."
  "${COMPOSE[@]}" build
fi

# --- Start the stack in the foreground ---
echo ""
echo "=== Starting dev stack ==="
echo "    Server: http://localhost:8000    (docs: /docs)"
echo "    Redis:  db=1 (prod=db=0)"
echo "    Live reload from: $SCRIPT_DIR/asu/asu"
echo "    Press Ctrl+C to stop"
echo ""
exec "${COMPOSE[@]}" up
