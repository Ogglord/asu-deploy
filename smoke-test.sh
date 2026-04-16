#!/usr/bin/env bash
# smoke-test.sh — probe ASU's read-only endpoints after a code change.
#
# Exercises everything that doesn't enqueue a build: HTML pages, the JSON
# v1 endpoints, OpenAPI docs, parameterized /api/v1/revision and per-arch
# package-index calls derived from whatever branches.json currently
# advertises, and a sanity check on the upstream's on-disk package layout.
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
  # Usage: probe <name> <absolute-url-or-path> [jq-check]
  # If the second arg starts with http(s):// it's used verbatim;
  # otherwise it's appended to $BASE.
  local name="$1" target="$2" check="${3:-}"
  local url tmp code
  case "$target" in
    http://*|https://*) url="$target" ;;
    *)                  url="$BASE$target" ;;
  esac
  tmp=$(mktemp)
  code=$(curl -sS -m 10 -o "$tmp" -w "%{http_code}" "$url" 2>/dev/null) || code="ERR"

  if [[ "$code" =~ ^2 ]]; then
    if [[ -n "$check" ]] && ! jq -e "$check" "$tmp" >/dev/null 2>&1; then
      printf "  FAIL %s %-52s content check failed: %s\n" "$code" "$target" "$check"
      echo "       body: $(head -c 200 "$tmp")"
      FAIL=$((FAIL + 1))
    else
      printf "  OK   %s %-52s %s\n" "$code" "$target" "$name"
      PASS=$((PASS + 1))
    fi
  else
    printf "  FAIL %s %-52s %s\n" "$code" "$target" "$name"
    echo "       body: $(head -c 200 "$tmp")"
    FAIL=$((FAIL + 1))
  fi
  rm -f "$tmp"
}

echo "=== Smoke-testing $BASE ==="

# --- HTML + static ---
probe "index"           "/"
probe "stats page"      "/stats"
probe "OpenAPI docs"    "/docs"
probe "static asset"    "/static/style.css"

# --- JSON v1 endpoints — the ones this fork has to get right ---
probe "latest.json"     "/json/v1/latest.json"     '.latest | type == "array" and length > 0'
probe "branches.json"   "/json/v1/branches.json"   '. | type == "array" and length > 0 and any(.enabled)'
probe "overview.json"   "/json/v1/overview.json"   '(.branches | length > 0) and (.server.version != null)'

# --- Discover state from branches + overview so probes track current data ---
BRANCHES_JSON=$(curl -fsS -m 10 "$BASE/json/v1/branches.json" 2>/dev/null || echo '[]')
OVERVIEW_JSON=$(curl -fsS -m 10 "$BASE/json/v1/overview.json" 2>/dev/null || echo '{}')
UPSTREAM=$(echo "$OVERVIEW_JSON" | jq -r '.upstream_url // empty' | sed 's:/*$::')

# Iterate over every enabled branch/version combo — partial migrations
# (one version published in the new layout, another still on the old one)
# would previously pass if the first-sorted branch was the good one.
BRANCH_COUNT=$(echo "$BRANCHES_JSON" | jq 'map(select(.enabled)) | length')
if [[ -z "$UPSTREAM" || "$BRANCH_COUNT" == "0" ]]; then
  echo "  SKIP no enabled branches or upstream_url unknown — per-version probes skipped"
else
  echo ""
  echo "=== Per-branch probes (upstream: $UPSTREAM) ==="

  # Emit one {version, target, arch} triple per enabled version.
  while IFS=$'\t' read -r VERSION TARGET ARCH; do
    [[ -z "$VERSION" ]] && continue
    IFS='/' read -r TGT SUBTGT <<<"$TARGET"
    echo ""
    echo "--- $VERSION ($TARGET / $ARCH) ---"

    # ASU endpoints — silently returned empty maps when the layout was
    # wrong; assert non-empty so regressions are caught.
    probe "revision"                 "/api/v1/revision/$VERSION/$TGT/$SUBTGT" \
          '.revision // .detail'
    probe "arch pkg index non-empty" "/json/v1/releases/$VERSION/packages/${ARCH}-index.json" \
          '. | type == "object" and length > 0'
    probe "target kmods non-empty"   "/json/v1/releases/$VERSION/targets/$TGT/$SUBTGT/index.json" \
          '.packages | type == "object" and length > 0'

    # Upstream layout sanity.
    probe "upstream feeds.conf"      "$UPSTREAM/releases/$VERSION/packages/$ARCH/feeds.conf"
    probe "upstream profiles.json"   "$UPSTREAM/releases/$VERSION/targets/$TGT/$SUBTGT/profiles.json"
    probe "upstream target kmods"    "$UPSTREAM/releases/$VERSION/targets/$TGT/$SUBTGT/packages/index.json"

    FIRST_FEED=$(curl -fsS -m 10 "$UPSTREAM/releases/$VERSION/packages/$ARCH/feeds.conf" 2>/dev/null \
                 | awk 'NF>=2 {print $2; exit}')
    if [[ -n "$FIRST_FEED" ]]; then
      probe "upstream feed '$FIRST_FEED'" \
            "$UPSTREAM/releases/$VERSION/packages/$ARCH/$FIRST_FEED/index.json"
    fi
  done < <(echo "$BRANCHES_JSON" | jq -r '
    .[] | select(.enabled) | .versions[] as $v
    | (.targets | to_entries[]) as $t
    | [$v, $t.key, $t.value] | @tsv
  ')
fi

echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "=== OK: $PASS passed ==="
  exit 0
else
  echo "=== FAIL: $PASS passed, $FAIL failed ==="
  exit 1
fi
