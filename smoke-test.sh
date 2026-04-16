#!/usr/bin/env bash
# smoke-test.sh — probe ASU's read-only endpoints after a code change.
#
# Exercises everything that doesn't enqueue a build: HTML pages, the JSON
# v1 endpoints, OpenAPI docs, and a parameterized /api/v1/revision call
# derived from whatever branches.json currently advertises.
#
# Usage:
#   ./smoke-test.sh                          # localhost:8000
#   ./smoke-test.sh https://asu.example.com  # against prod tunnel
#
# Requires: curl, jq.
set -uo pipefail

BASE="${1:-http://localhost:8000}"
PASS=0
FAIL=0

probe() {
  local name="$1" path="$2" check="${3:-}"
  local tmp rc code
  tmp=$(mktemp)
  code=$(curl -sS -m 10 -o "$tmp" -w "%{http_code}" "$BASE$path" 2>/dev/null) || code="ERR"

  if [[ "$code" =~ ^2 ]]; then
    if [[ -n "$check" ]] && ! jq -e "$check" "$tmp" >/dev/null 2>&1; then
      printf "  FAIL %s %-48s content check failed: %s\n" "$code" "$path" "$check"
      echo "       body: $(head -c 200 "$tmp")"
      FAIL=$((FAIL + 1))
    else
      printf "  OK   %s %-48s %s\n" "$code" "$path" "$name"
      PASS=$((PASS + 1))
    fi
  else
    printf "  FAIL %s %-48s %s\n" "$code" "$path" "$name"
    echo "       body: $(head -c 200 "$tmp")"
    FAIL=$((FAIL + 1))
  fi
  rm -f "$tmp"
}

echo "=== Smoke-testing $BASE ==="

# HTML + static
probe "index"           "/"
probe "stats page"      "/stats"
probe "OpenAPI docs"    "/docs"
probe "static asset"    "/static/style.css"

# JSON v1 endpoints — the ones this fork actually has to get right
probe "latest.json"     "/json/v1/latest.json"     '.latest | type == "array" and length > 0'
probe "branches.json"   "/json/v1/branches.json"   '. | type == "array" and length > 0 and any(.enabled)'
probe "overview.json"   "/json/v1/overview.json"   '(.branches | length > 0) and (.server.version != null)'

# Upstream passthrough — picks any branch/version that branches.json lists,
# so we don't hardcode a version that rots.
PROBE_JSON=$(curl -fsS -m 10 "$BASE/json/v1/branches.json" 2>/dev/null || echo '[]')
VERSION=$(echo "$PROBE_JSON" | jq -r '[.[] | select(.enabled) | .versions[0]] | .[0] // empty')
TARGET=$(echo "$PROBE_JSON" | jq -r '[.[] | select(.enabled) | (.targets | keys[0])] | .[0] // empty')

if [[ -n "$VERSION" && -n "$TARGET" ]]; then
  IFS='/' read -r TGT SUBTGT <<<"$TARGET"
  probe "revision ($VERSION $TARGET)" \
        "/api/v1/revision/$VERSION/$TGT/$SUBTGT" \
        '.revision // .detail'
  probe "profile passthrough" \
        "/json/v1/releases/$VERSION/targets/$TGT/$SUBTGT/index.json"
else
  echo "  SKIP no enabled branch found in branches.json — revision/profile probes skipped"
fi

echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "=== OK: $PASS passed ==="
  exit 0
else
  echo "=== FAIL: $PASS passed, $FAIL failed ==="
  exit 1
fi
