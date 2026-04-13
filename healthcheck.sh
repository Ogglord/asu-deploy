#!/usr/bin/env bash
# ASU Server health check -- called by systemd timer every 5 minutes
# Pings healthcheck.io with success/failure based on API availability

set -euo pipefail

# Read HC_UUID from .env if not set
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${HC_UUID:-}" ]] && [[ -f "$SCRIPT_DIR/.env" ]]; then
  HC_UUID=$(grep -oP '^HC_UUID=\K.*' "$SCRIPT_DIR/.env" || true)
fi

if [[ -z "${HC_UUID:-}" ]]; then
  echo "Error: HC_UUID not set. Add it to .env"
  exit 1
fi

if curl -fsS -m 10 http://localhost:8000/api/v1/revision > /dev/null 2>&1; then
  curl -fsS -m 10 --retry 3 "https://hc-ping.com/${HC_UUID}" || true
else
  curl -fsS -m 10 --retry 3 "https://hc-ping.com/${HC_UUID}/fail" || true
fi
