#!/usr/bin/env bash
set -euo pipefail

BRANCHES_URL="https://raw.githubusercontent.com/Ogglord/openwrt-imagebuilder-mt6000/releases/branches.json"
ENV_FILE="/home/asu/asu-server/.env"
COMPOSE_DIR="/home/asu/asu-server"

# Fetch and validate
JSON=$(curl -fsSL "$BRANCHES_URL")
echo "$JSON" | jq empty

# Compact to single line for .env
BRANCHES=$(echo "$JSON" | jq -c .)

# Check if BRANCHES value actually changed
CURRENT=$(grep '^BRANCHES=' "$ENV_FILE" | cut -d= -f2- || true)
if [[ "$CURRENT" == "$BRANCHES" ]]; then
  echo "branches.json unchanged, nothing to do"
  exit 0
fi

echo "New branches detected, updating .env and restarting stack..."

# Update or insert BRANCHES= in .env
if grep -q '^BRANCHES=' "$ENV_FILE"; then
  sed -i "s|^BRANCHES=.*|BRANCHES=${BRANCHES}|" "$ENV_FILE"
else
  echo "BRANCHES=${BRANCHES}" >> "$ENV_FILE"
fi

# Restart the ASU stack to pick up new config
cd "$COMPOSE_DIR"
podman-compose up -d
